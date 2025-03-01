!
! Copyright (C) 2002-2022 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!----------------------------------------------------------------------
SUBROUTINE force_hub( forceh )
   !----------------------------------------------------------------------
   !! This routine computes the Hubbard contribution to the force. It gives
   !! as output the product:
   !! $$ \frac{dE_\text{hub}}{dn_{ij}^\alpha}\cdot\frac{dn_{ij}^\alpha} 
   !! {du}(\alpha,\text{ipol}) \ ,$$
   !! which is the force acting on the atom at \(\text{tau_alpha}\)
   !! (in the unit cell) along the direction \(\text{ipol}\).
   !!  Note: DFT+U+V force does not support OpenMP.
   !
   USE kinds,                ONLY : DP
   USE ions_base,            ONLY : nat, ntyp => nsp, ityp
   USE cell_base,            ONLY : at, bg
   USE ldaU,                 ONLY : hubbard_lmax, hubbard_l, Hubbard_projectors, &
                                    nwfcU, wfcU, is_hubbard, lda_plus_u_kind,    &
                                    offsetU, is_hubbard_back, ldim_back, ldmx_b, &
                                    ldmx_tot, nsg, v_nsg, max_num_neighbors,     &
                                    ldim_u, Hubbard_V, at_sc, neighood, Hubbard_J
   USE basis,                ONLY : natomwfc, wfcatom, swfcatom
   USE symme,                ONLY : symvector
   USE wvfct,                ONLY : nbnd, npwx
   USE control_flags,        ONLY : gamma_only
   USE lsda_mod,             ONLY : lsda, nspin, current_spin, isk
   USE scf,                  ONLY : v
   USE becmod,               ONLY : bec_type, becp, calbec, allocate_bec_type, &
                                    deallocate_bec_type
   USE uspp,                 ONLY : nkb, vkb, ofsbeta
   USE uspp_param,           ONLY : nh
   USE wavefunctions,        ONLY : evc
   USE wavefunctions_gpum,   ONLY : evc_d, using_evc, using_evc_d
   USE klist,                ONLY : nks, xk, ngk, igk_k
   USE io_files,             ONLY : nwordwfc, iunwfc
   USE buffers,              ONLY : get_buffer
   USE mp_bands,             ONLY : use_bgrp_in_hpsi
   USE noncollin_module,     ONLY : noncolin
   USE force_mod,            ONLY : eigenval, eigenvect, overlap_inv
   USE becmod_gpum,          ONLY : bec_type_d, becp_d
   USE becmod_subs_gpum,     ONLY : calbec_gpu, using_becp_auto, using_becp_d_auto, &
                                    allocate_bec_type_gpu, deallocate_bec_type_gpu
   USE uspp_init,            ONLY : init_us_2
   USE constants,            ONLY : eps16
   USE mp_pools,             ONLY : inter_pool_comm, intra_pool_comm, me_pool, &
                                    nproc_pool
   USE mp,                   ONLY : mp_sum
   !
   IMPLICIT NONE
   !
   REAL(DP) :: forceh(3,nat)
   !! the Hubbard forces
   !
   ! ... local variables
   !
#if defined(__CUDA)
   TYPE(bec_type_d) :: proj     ! proj(nwfcU,nbnd)
#else
   TYPE(bec_type) :: proj
#endif
   COMPLEX(DP), ALLOCATABLE :: spsi(:,:)
   REAL(DP), ALLOCATABLE :: dns(:,:,:,:), dnsb(:,:,:,:)
   COMPLEX (DP), ALLOCATABLE ::  dnsg(:,:,:,:,:)
   ! dns(ldim,ldim,nspin,nat) ! the derivative of the atomic occupations
   INTEGER :: npw, alpha, na, nt, is, m1, m2, ipol, ldim, ik, ijkb0
   INTEGER :: na1, na2, equiv_na2, nt1, nt2, ldim1, ldim2, viz
   INTEGER :: nb_s, nb_e, mykey, ldimb
   LOGICAL :: lhubb
   LOGICAL :: save_flag
   !
   REAL(DP), ALLOCATABLE :: projrd(:,:)
   COMPLEX(DP), ALLOCATABLE :: projkd(:,:)
   !
   CALL start_clock_gpu( 'force_hub' )
   !
   save_flag = use_bgrp_in_hpsi ; use_bgrp_in_hpsi = .FALSE.
   !
   IF (.NOT.((Hubbard_projectors.EQ."atomic") .OR. (Hubbard_projectors.EQ."ortho-atomic"))) &
      CALL errore( "force_hub", &
                   " forces for this Hubbard_projectors type not implemented", 1 )
   !
   IF (noncolin) CALL errore( "forceh","Noncollinear case is not supported", 1 )
   !
   IF (ANY(Hubbard_J(:,:)>eps16)) CALL errore( "force_hub", &
                   " forces in the DFT+U+J scheme are not implemented", 1 )
   !
   IF (lda_plus_u_kind==0) THEN
      ! ... DFT+U
      lhubb = .FALSE.
      ldim = 2*Hubbard_lmax + 1
      ALLOCATE( dns(ldim,ldim,nspin,nat) )
      DO nt = 1, ntyp
         IF (is_hubbard_back(nt)) lhubb = .TRUE.
      ENDDO
      IF (lhubb) THEN
         ldimb = ldmx_b
         ALLOCATE( dnsb(ldimb,ldimb,nspin,nat) )
      ENDIF
   ELSEIF (lda_plus_u_kind==2) THEN
      ! ... DFT+U+V
      ldim = ldmx_tot
      ALLOCATE( dnsg(ldim,ldim,max_num_neighbors,nat,nspin) )
   ENDIF
   !
   ALLOCATE( spsi(npwx,nbnd) ) 
   ALLOCATE( wfcatom(npwx,natomwfc) )
   IF (Hubbard_projectors.EQ."ortho-atomic") THEN
      ALLOCATE( swfcatom(npwx,natomwfc) )
      ALLOCATE( eigenval(natomwfc) )
      ALLOCATE( eigenvect(natomwfc,natomwfc) )
      ALLOCATE( overlap_inv(natomwfc,natomwfc) )
   ENDIF
   !
   !$acc data create(spsi) copyin(wfcU)
   !
#if defined(__CUDA)
   CALL allocate_bec_type_gpu( nwfcU, nbnd, proj )
   CALL using_evc_d(0)
#else
   CALL allocate_bec_type( nwfcU, nbnd, proj )
   CALL using_evc(0)
#endif
   !
   ! ... poor-man parallelization over bands:
   !      - if nproc_pool=1 : nb_s=1, nb_e=nbnd, mykey=0;
   !      - if nproc_pool<=nbnd: each processor calculates band nb_s to nb_e; mykey=0;
   !      - if nproc_pool>nbnd :each processor takes care of band na_s=nb_e;
   !        mykey labels how many times each band appears (mykey=0 first time etc.)
   !
   CALL block_distribute( nbnd, me_pool, nproc_pool, nb_s, nb_e, mykey )
   !
   forceh(:,:) = 0.d0
   !
   ! ... we start a loop on k-points
   !
   DO ik = 1, nks
      !
      IF (lsda) current_spin = isk(ik)
      npw = ngk(ik)
      !
      IF (nks > 1) CALL using_evc(2)
      IF (nks > 1) CALL get_buffer( evc, nwordwfc, iunwfc, ik )
      !
      CALL init_us_2( npw, igk_k(1,ik), xk(1,ik), vkb, .TRUE. )
      ! ... FIXME check if this update is actually needed and in case comment
      ! ...       indicating why. 
      !
      !$acc update self(vkb)
      !
      ! ... Compute spsi = S * psi
      CALL allocate_bec_type( nkb, nbnd, becp )
      CALL using_becp_auto(2)
      !
#if defined(__CUDA)
      CALL using_evc_d(0)
      CALL using_becp_d_auto(2)
      !$acc host_data use_device(vkb,spsi)
      CALL calbec_gpu( npw, vkb, evc_d, becp_d )
      CALL s_psi_gpu( npwx, npw, nbnd, evc_d, spsi )
      !$acc end host_data
#else
      CALL calbec( npw, vkb, evc, becp )
      CALL s_psi( npwx, npw, nbnd, evc, spsi )
#endif
      CALL deallocate_bec_type( becp )
      CALL using_becp_auto(2)
      !
      ! ... Set up various quantities, in particular wfcU which 
      ! ... contains Hubbard-U (ortho-)atomic wavefunctions (without ultrasoft S)
      CALL orthoUwfc_k( ik, .TRUE. )
      !$acc update device(wfcU)
      !
      IF ( gamma_only ) THEN
         ALLOCATE( projrd(nwfcU,nbnd) )
      ELSE
         ALLOCATE( projkd(nwfcU,nbnd) )
      ENDIF
      !
      ! ... proj=<wfcU|S|evc>
#if defined(__CUDA)
      CALL using_becp_d_auto(2)
      !$acc host_data use_device( spsi, wfcU )
      CALL calbec_gpu( npw, wfcU, spsi, proj )
      !$acc end host_data
      !
      IF ( gamma_only ) THEN
         projrd = proj%r_d
      ELSE
         projkd = proj%k_d
      ENDIF
      !$acc data copyin(projrd,projkd,wfcatom,overlap_inv)
#else
      CALL calbec( npw, wfcU, spsi, proj )
      !
      IF ( gamma_only ) THEN
         projrd = proj%r
      ELSE
         projkd = proj%k
      ENDIF
#endif
      ! ... now we need the first derivative of proj with respect to tau(alpha,ipol)
      !
      DO alpha = 1, nat  ! forces are calculated by displacing atom alpha ...
         !
         ijkb0 = ofsbeta(alpha) ! positions of beta functions for atom alpha
         !
         IF (lda_plus_u_kind==0) THEN
            !
            DO ipol = 1, 3  ! forces are calculated for coordinate ipol ...
               !
               IF ( gamma_only ) THEN
                  CALL dndtau_gamma( ldim, projrd, spsi, alpha, ijkb0, ipol, ik, &
                                         nb_s, nb_e, mykey, 1, dns )
               ELSE
                  CALL dndtau_k( ldim, projkd, spsi, alpha, ijkb0, ipol, ik, &
                                     nb_s, nb_e, mykey, 1, dns )
               ENDIF
               !
! !omp parallel do default(shared) private(na,nt,m1,m2,is)
               DO na = 1, nat                
                  nt = ityp(na)
                  IF ( is_hubbard(nt) ) THEN
                     DO is = 1, nspin
                        DO m2 = 1, 2*Hubbard_l(nt)+1
                           DO m1 = 1, 2*Hubbard_l(nt)+1
                              forceh(ipol,alpha) = forceh(ipol,alpha) -    &
                                 v%ns(m2,m1,is,na) * dns(m1,m2,is,na)
                           ENDDO
                        ENDDO
                     ENDDO
                  ENDIF
               ENDDO
! !omp end parallel do
               !
               IF (lhubb) THEN
                  IF ( gamma_only ) THEN
                     CALL dndtau_gamma( ldimb, projrd, spsi, alpha, ijkb0, ipol, ik, &
                                        nb_s, nb_e, mykey, 2, dnsb )
                  ELSE
                     CALL dndtau_k( ldimb, projkd, spsi, alpha, ijkb0, ipol, ik, &
                                    nb_s, nb_e, mykey, 2, dnsb )
                  ENDIF
                  !
! !omp parallel do default(shared) private(na,nt,m1,m2,is)
                  DO na = 1,nat              
                     nt = ityp(na)
                     IF ( is_hubbard_back(nt) ) THEN
                        DO is = 1,nspin
                           DO m2 = 1,ldim_back(nt)
                              DO m1 = 1,ldim_back(nt)
                                 forceh(ipol,alpha) = forceh(ipol,alpha) -    &
                                    v%nsb(m2,m1,is,na) * dnsb(m1,m2,is,na)
                              ENDDO
                           ENDDO
                        ENDDO
                     ENDIF
                  ENDDO
! !omp end parallel do
               ENDIF
            ENDDO ! ipol
            !
         ELSEIF (lda_plus_u_kind==2) THEN
            !
            DO ipol = 1, 3  ! forces are calculated for coordinate ipol ...
               !
               IF ( gamma_only ) THEN
                  CALL dngdtau_gamma( ldim, projrd, spsi, alpha, ijkb0, ipol, ik, &
                                      nb_s, nb_e, mykey, dnsg )
               ELSE
                  CALL dngdtau_k( ldim, projkd, spsi, alpha, ijkb0, ipol, ik, &
                                  nb_s, nb_e, mykey, dnsg )
               ENDIF
               !
               DO is = 1, nspin
                  DO na1 = 1, nat
                     nt1 = ityp(na1)
                     IF ( is_hubbard(nt1) ) THEN
                        ldim1 = ldim_u(nt1)
                        DO viz = 1, neighood(na1)%num_neigh
                           na2 = neighood(na1)%neigh(viz)
                           equiv_na2 = at_sc(na2)%at
                           nt2 = ityp(equiv_na2)
                           ldim2 = ldim_u(nt2)
                           IF (Hubbard_V(na1,na2,1)/=0.d0 .OR. &
                               Hubbard_V(na1,na2,2)/=0.d0 .OR. &
                               Hubbard_V(na1,na2,3)/=0.d0 .OR. &
                               Hubbard_V(na1,na2,4)/=0.d0 ) THEN
                               DO m1 = 1, ldim1
                                  DO m2 = 1, ldim2
                                     forceh(ipol,alpha) = forceh(ipol,alpha) &
                                        - DBLE(v_nsg(m2,m1,viz,na1,is) * dnsg(m2,m1,viz,na1,is))
                                  ENDDO 
                               ENDDO 
                           ENDIF
                        ENDDO ! viz
                     ENDIF
                  ENDDO ! na1
               ENDDO ! is
               !
            ENDDO ! ipol
            !
         ENDIF
         !
      ENDDO ! alpha
      !
      !$acc end data
      IF ( gamma_only ) THEN
        DEALLOCATE( projrd )
      ELSE
        DEALLOCATE( projkd )
      ENDIF
      !
   ENDDO ! ik
   !
   CALL mp_sum( forceh, inter_pool_comm )
   !
#if defined(__CUDA)
   CALL deallocate_bec_type_gpu( proj )
#else
   CALL deallocate_bec_type( proj )
#endif
   !
   IF (lda_plus_u_kind==0) THEN
      DEALLOCATE( dns )
      IF (ALLOCATED(dnsb)) DEALLOCATE( dnsb )
   ELSEIF (lda_plus_u_kind==2) THEN
      DEALLOCATE( dnsg )
   ENDIF
   !
   !$acc end data
   !
   DEALLOCATE( spsi )
   DEALLOCATE( wfcatom )
   IF (Hubbard_projectors.EQ."ortho-atomic") THEN
      DEALLOCATE( swfcatom )
      DEALLOCATE( eigenval )
      DEALLOCATE( eigenvect )
      DEALLOCATE( overlap_inv )
   ENDIF
   !
   IF (nspin == 1) forceh(:,:) = 2.d0 * forceh(:,:)
   !
   ! symmetrize
   !
   CALL symvector( nat, forceh )
   !
#if defined(__DEBUG)
   WRITE( 66,'("Hubbard contribution Begin")' )
   WRITE( 66,'(3f12.6)' ) forceh(:,:)
   WRITE( 66,'("Hubbard contribution End")' )
#endif
   use_bgrp_in_hpsi = save_flag
   !
   CALL stop_clock_gpu( 'force_hub' )
   !
   RETURN
   !
END SUBROUTINE force_hub
!
!
!------------------------------------------------------------------------------
SUBROUTINE dndtau_k( ldim, proj, spsi, alpha, jkb0, ipol, ik, nb_s, &
                     nb_e, mykey, lpuk, dns )
   !---------------------------------------------------------------------------
   !! This routine computes the derivative of the ns with respect to the ionic
   !! displacement \(u(\text{alpha,ipol})\) used to obtain the Hubbard 
   !! contribution to the atomic forces.
   !
   USE kinds,                ONLY : DP
   USE ions_base,            ONLY : nat, ityp
   USE lsda_mod,             ONLY : nspin, current_spin
   USE ldaU,                 ONLY : nwfcU, offsetU, is_hubbard_back, offsetU_back, &
                                    ldim_u, offsetU_back1, ldim_back, Hubbard_l2,  &
                                    backall, Hubbard_projectors, wfcU, is_hubbard, &
                                    Hubbard_l
   USE wvfct,                ONLY : nbnd, npwx, wg
   USE uspp,                 ONLY : okvan
   USE force_mod,            ONLY : doverlap_inv
   USE basis,                ONLY : natomwfc
   USE wavefunctions,        ONLY : evc
   USE wavefunctions_gpum,   ONLY : using_evc, using_evc_d
   USE mp_pools,             ONLY : intra_pool_comm, me_pool, nproc_pool
   USE mp,                   ONLY : mp_sum
   !
   IMPLICIT NONE
   !
   INTEGER, INTENT(IN) :: ldim
   !! ldim = 2*Hubbard_lmax+1
   COMPLEX(DP), INTENT(IN) :: proj(nwfcU,nbnd)
   !! projection
   COMPLEX(DP), INTENT(IN) :: spsi(npwx,nbnd)
   !! \(S|\ \text{evc}\rangle\)
   INTEGER, INTENT(IN) :: alpha
   !! the displaced atom index
   INTEGER, INTENT(IN) :: jkb0
   !! positions of beta functions for atom alpha
   INTEGER, INTENT(IN) :: ipol
   !! the component of displacement
   INTEGER, INTENT(IN) :: ik
   !! k-point index
   INTEGER, INTENT(IN) :: nb_s
   !! starting band number (for band parallelization)
   INTEGER, INTENT(IN) :: nb_e
   !! ending band number (for band parallelization)
   INTEGER, INTENT(IN) :: mykey
   !! If each band appears more than once
   !! compute its contribution only once (i.e. when mykey=0)
   INTEGER, INTENT(IN) :: lpuk
   !! index to control the standard (lpuk=1) or 
   !! background (lpuk=2) contribution to the force
   REAL(DP), INTENT(OUT) :: dns(ldim,ldim,nspin,nat)
   !! the derivative of the atomic occupations
   !
   ! ... local variables
   !
   INTEGER :: ibnd, is, na, nt, m1, m2, off1, off2, m11, m22, ldim1
   COMPLEX(DP), ALLOCATABLE :: dproj(:,:), dproj_us(:,:)
   !
   CALL start_clock( 'dndtau' )
   !
#if defined(__CUDA)
  CALL using_evc(0)
  CALL using_evc_d(0)
#endif
   !
   ALLOCATE( dproj(nwfcU,nb_s:nb_e) )
   IF (okvan) ALLOCATE( dproj_us(nwfcU,nb_s:nb_e) )
   !
   !$acc data present_or_copyin(spsi,proj,wfcU) create(dproj,dproj_us)
   !
   ! ... Compute the derivative of occupation matrices (the quantities dns(m1,m2))
   ! ... of the atomic orbitals. They are real quantities as well as ns(m1,m2).
   !
   dns(:,:,:,:) = 0.d0
   !
   ! ... Compute the USPP contribution to dproj:
   ! ... <\phi^{at}_{I,m1}|dS/du(alpha,ipol)|\psi_{k,v,s}>
   !
   IF (okvan) THEN
      !$acc data copyin( evc )
      CALL matrix_element_of_dSdtau( alpha, ipol, ik, jkb0, nwfcU, wfcU, &
                                     nbnd, evc, dproj_us, nb_s, nb_e, mykey )
      !$acc end data
   ENDIF
   !
   ! ... In the 'ortho-atomic' case calculate d[(O^{-1/2})^T]
   !
   IF (Hubbard_projectors.EQ."ortho-atomic") THEN
      ALLOCATE( doverlap_inv(natomwfc,natomwfc) )
      CALL calc_doverlap_inv( alpha, ipol, ik, jkb0 )
   ENDIF
   !$acc data copyin(doverlap_inv)
   !
   ! ... Band parallelization. If each band appears more than once
   ! ... compute its contribution only once (i.e. when mykey=0)
   !
! !omp parallel do default(shared) private(na,nt,m1,m2,ibnd)
   DO na = 1, nat
      nt = ityp(na)
      IF (is_hubbard(nt) .AND. lpuk==1) THEN
         !
         ! ... Compute the derivative of proj
         CALL dprojdtau_k( spsi, alpha, na, jkb0, ipol, ik, nb_s, nb_e, &
                           mykey, dproj )
         !
         ! ... adds dproj_us to dproj_d with scaling 1.
         IF (okvan) THEN
           !$acc kernels
           dproj = dproj + dproj_us
           !$acc end kernels
         ENDIF
         !
         !$acc update self(dproj(:,nb_s:nb_e))
         IF (mykey==0) THEN
          DO m1 = 1, 2*Hubbard_l(nt)+1
            DO m2 = m1, 2*Hubbard_l(nt)+1
               DO ibnd = nb_s, nb_e
                  dns(m1,m2,current_spin,na) = dns(m1,m2,current_spin,na) +      &
                                               wg(ibnd,ik) *                     &
                                               DBLE( proj(offsetU(na)+m1,ibnd)*  &
                                               CONJG(dproj(offsetU(na)+m2,ibnd))+&
                                                     dproj(offsetU(na)+m1,ibnd)* &
                                               CONJG( proj(offsetU(na)+m2,ibnd)) )
               ENDDO
            ENDDO
          ENDDO
         ENDIF
      ELSEIF (is_hubbard_back(nt) .AND. lpuk==2) THEN
         !
         ! ... Compute the second contribution to dproj due to the derivative of 
         ! ... (ortho-)atomic orbitals
         CALL dprojdtau_k( spsi, alpha, na, jkb0, ipol, ik, nb_s, nb_e, &
                           mykey, dproj )
         !
         ! ... adds dproj_us to dproj_d with scaling 1.
         IF (okvan) THEN
           !$acc kernels
           dproj = dproj + dproj_us
           !$acc end kernels
         ENDIF
         !
         !$acc update self(dproj(:,nb_s:nb_e))
         IF (mykey==0) THEN
          DO m1 = 1, ldim_back(nt) 
            off1 = offsetU_back(na)
            m11 = m1
            IF (backall(nt) .AND. m1>2*Hubbard_l2(nt)+1) THEN
               off1 = offsetU_back1(na)
               m11 = m1 - 2*Hubbard_l2(nt)-1
            ENDIF
            DO m2 = m1, ldim_back(nt) 
               off2 = offsetU_back(na)
               m22 = m2
               IF (backall(nt) .AND. m2>2*Hubbard_l2(nt)+1) THEN
                  off2 = offsetU_back1(na)
                  m22 = m2 - 2*Hubbard_l2(nt)-1
               ENDIF
               DO ibnd = nb_s, nb_e
                  dns(m1,m2,current_spin,na) = dns(m1,m2,current_spin,na) + &
                                               wg(ibnd,ik) *            &
                                               DBLE( proj(off1+m11,ibnd)  *   &
                                               CONJG(dproj(off2+m22,ibnd))  +   &
                                                     dproj(off1+m11,ibnd)  *   &
                                               CONJG( proj(off2+m22,ibnd)) )
               ENDDO
            ENDDO
          ENDDO
         ENDIF
      ENDIF
   ENDDO
! !omp end parallel do
   !
   !$acc end data
   !$acc end data
   DEALLOCATE( dproj )
   IF (ALLOCATED(doverlap_inv)) DEALLOCATE( doverlap_inv )
   IF (okvan) DEALLOCATE( dproj_us )
   !
   CALL mp_sum( dns, intra_pool_comm )
   !
   ! ... In nspin=1 k-point weight wg is normalized to 2 el/band 
   ! ... in the whole BZ but we are interested in dns of one spin component
   !
   IF (nspin == 1) dns = 0.5d0 * dns
   !
   ! ... Impose hermiticity of dns_{m1,m2}
   !
! !omp parallel do default(shared) private(na,is,m1,m2)
   DO na = 1, nat
      DO is = 1, nspin
         DO m1 = 1, ldim
            DO m2 = m1+1, ldim
               dns(m2,m1,is,na) = dns(m1,m2,is,na)
            ENDDO
         ENDDO
      ENDDO
   ENDDO
! !omp end parallel do
   !
   CALL stop_clock( 'dndtau' )
   !
   RETURN
   !
END SUBROUTINE dndtau_k
!

!-----------------------------------------------------------------------
SUBROUTINE dndtau_gamma( ldim, rproj, spsi, alpha, jkb0, ipol, ik, &
                         nb_s, nb_e, mykey, lpuk, dns )
   !-----------------------------------------------------------------------
   !! This routine computes the derivative of the ns with respect to the
   !! ionic displacement \(u(\text{alpha,ipol})\) used to obtain the Hubbard
   !! contribution to the atomic forces.
   !
   USE kinds,                ONLY : DP
   USE ions_base,            ONLY : nat, ityp
   USE lsda_mod,             ONLY : nspin, current_spin
   USE ldaU,                 ONLY : is_hubbard, Hubbard_l, nwfcU, offsetU, &
                                    is_hubbard_back, ldim_back, offsetU_back, &
                                    Hubbard_l2, offsetU_back1
   USE wvfct,                ONLY : nbnd, npwx, wg
   USE mp_pools,             ONLY : intra_pool_comm, me_pool, nproc_pool
   USE mp,                   ONLY : mp_sum
   !
   IMPLICIT NONE
   !
   INTEGER, INTENT(IN) :: ldim
   !! ldim = 2*Hubbard_lmax+1
   REAL(DP), INTENT(IN) :: rproj(nwfcU,nbnd)
   !! projection
   COMPLEX(DP), INTENT(IN) :: spsi(npwx,nbnd)
   !! \(S\ |\text{evc}\rangle\)
   INTEGER, INTENT(IN) :: alpha
   !! the displaced atom index
   INTEGER, INTENT(IN) :: jkb0
   !! positions of beta functions for atom alpha
   INTEGER, INTENT(IN) :: ipol
   !! the component of displacement
   INTEGER, INTENT(IN) :: ik
   !! k-point index
   INTEGER, INTENT(IN) :: nb_s
   !! starting band number (for band parallelization)
   INTEGER, INTENT(IN) :: nb_e
   !! ending band number (for band parallelization)
   INTEGER, INTENT(IN) :: mykey
   !! If each band appears more than once compute
   !! its contribution only once (i.e. when
   !! \(\text{mykey}=0)\)
   INTEGER, INTENT(IN) :: lpuk
   !! index to control the standard (lpuk=1) or 
   !! background (lpuk=2) contribution to the force
   REAL(DP), INTENT(OUT) :: dns(ldim,ldim,nspin,nat)
   !! the derivative of the atomic occupations
   !
   ! ... local variables
   !
   INTEGER ::  ibnd, is, na, nt, m1, m2, off1, off2, m11, m22
   REAL(DP), ALLOCATABLE :: dproj(:,:)
   !
   CALL start_clock( 'dndtau' )
   !
   ALLOCATE( dproj(nwfcU,nb_s:nb_e) )
   !
   !$acc data present_or_copyin(rproj,spsi) create(dproj)
   !
   ! ... Compute the derivative of occupation matrices (the quantities dns(m1,m2))
   ! ... of the atomic orbitals. They are real quantities as well as ns(m1,m2).
   !
   CALL dprojdtau_gamma( spsi, alpha, jkb0, ipol, ik, nb_s, nb_e, mykey, dproj )
   !
   !$acc update self(dproj(:,nb_s:nb_e))
   !
   dns(:,:,:,:) = 0.d0
   !
   ! ... Band parallelization. If each band appears more than once
   ! ... compute its contribution only once (i.e. when mykey=0)
   !
   IF ( mykey /= 0 ) GO TO 10
   !
! !omp parallel do default(shared) private(na,nt,m1,m2,is)
   DO na = 1, nat
      nt = ityp(na)
      IF (is_hubbard(nt) .AND. lpuk==1) THEN
         DO m1 = 1, 2*Hubbard_l(nt)+1
            DO m2 = m1, 2*Hubbard_l(nt)+1
               DO ibnd = nb_s, nb_e
                  dns(m1,m2,current_spin,na) = dns(m1,m2,current_spin,na) + &
                                               wg(ibnd,ik) * (              &
                                               rproj(offsetU(na)+m1,ibnd)*  &
                                               dproj(offsetU(na)+m2,ibnd) + &
                                               dproj(offsetU(na)+m1,ibnd)*  &
                                               rproj(offsetU(na)+m2,ibnd)   )
               ENDDO
            ENDDO
         ENDDO
      ELSEIF (is_hubbard_back(nt) .AND. lpuk==2) THEN
         DO m1 = 1, ldim_back(nt) 
            off1 = offsetU_back(na)
            m11 = m1
            IF (m1>2*Hubbard_l2(nt)+1) THEN
               off1 = offsetU_back1(na)
               m11 = m1 - 2*Hubbard_l2(nt)-1
            ENDIF
            DO m2 = m1, ldim_back(nt) 
               off2 = offsetU_back(na)
               m22 = m2
               IF (m2>2*Hubbard_l2(nt)+1) THEN
                  off2 = offsetU_back1(na)
                  m22 = m2 - 2*Hubbard_l2(nt)-1
               ENDIF
               DO ibnd = nb_s, nb_e
                  dns(m1,m2,current_spin,na) = dns(m1,m2,current_spin,na) + &
                                               wg(ibnd,ik) * (              &
                                               rproj(off1+m11,ibnd)  *      &
                                               dproj(off2+m22,ibnd)  +      &
                                               dproj(off1+m11,ibnd)  *      &
                                               rproj(off2+m22,ibnd) )
               ENDDO
            ENDDO
         ENDDO
      ENDIF
   ENDDO
! !omp end parallel do
   !
10 CONTINUE
   !
   !$acc end data
   DEALLOCATE( dproj )
   !
   CALL mp_sum( dns, intra_pool_comm )
   !
   ! ... In nspin=1 k-point weight wg is normalized to 2 el/band 
   ! ... in the whole BZ but we are interested in dns of one spin component
   !
   IF (nspin == 1) dns = 0.5d0 * dns
   !
   ! ... Impose hermiticity of dns_{m1,m2}
   !
! !omp parallel do default(shared) private(na,is,m1,m2)
   DO na = 1, nat
      DO is = 1, nspin
         DO m1 = 1, ldim
            DO m2 = m1+1, ldim
               dns(m2,m1,is,na) = dns(m1,m2,is,na)
            ENDDO
         ENDDO
      ENDDO
   ENDDO
! !omp end parallel do
   !
   CALL stop_clock( 'dndtau' )
   !
   RETURN
   !
END SUBROUTINE dndtau_gamma
!
!
!----------------------------------------------------------------------------
SUBROUTINE dngdtau_k( ldim, proj, spsi, alpha, jkb0, ipol, ik, nb_s, &
                          nb_e, mykey, dnsg )
   !-------------------------------------------------------------------------
   !! This routine computes the derivative of the nsg (generalized occupation
   !! matrix of the DFT+U+V scheme) with respect to the ionic
   !! displacement \(u(\text{alpha,ipol})\) used to obtain the generalized 
   !! Hubbard contribution to the atomic forces.
   !
   USE kinds,                ONLY : DP
   USE ions_base,            ONLY : nat, ityp
   USE lsda_mod,             ONLY : nspin, current_spin
   USE ldaU,                 ONLY : is_hubbard, Hubbard_l, nwfcU, offsetU, at_sc,  &
                                    offsetU_back, offsetU_back1, Hubbard_l2,   &
                                    backall, max_num_neighbors, phase_fac, ldim_u, &
                                    neighood, Hubbard_projectors, wfcU
   USE wvfct,                ONLY : nbnd, npwx, npw, wg
   USE uspp,                 ONLY : okvan
   USE force_mod,            ONLY : doverlap_inv
   USE basis,                ONLY : natomwfc
   USE wavefunctions,        ONLY : evc
   USE wavefunctions_gpum,   ONLY : evc_d, using_evc, using_evc_d
   USE mp_pools,             ONLY : intra_pool_comm, me_pool, nproc_pool
   USE mp,                   ONLY : mp_sum
   !
   IMPLICIT NONE
   !
   INTEGER, INTENT(IN) :: ldim
   !! ldim = 2*Hubbard_lmax+1
   COMPLEX(DP), INTENT(IN) :: proj(nwfcU,nbnd)
   !! projection
   COMPLEX(DP), INTENT(IN) :: spsi(npwx,nbnd)
   !! \(S|\ \text{evc}\rangle\)
   INTEGER, INTENT(IN) :: alpha
   !! the displaced atom index
   INTEGER, INTENT(IN) :: jkb0
   !! positions of beta functions for atom alpha
   INTEGER, INTENT(IN) :: ipol
   !! the component of displacement
   INTEGER, INTENT(IN) :: ik
   !! k-point index
   INTEGER, INTENT(IN) :: nb_s
   !! starting band number (for band parallelization)
   INTEGER, INTENT(IN) :: nb_e
   !! ending band number (for band parallelization)
   INTEGER, INTENT(IN) :: mykey
   !! If each band appears more than once
   !! compute its contribution only once (i.e. when mykey=0)
   COMPLEX(DP), INTENT(OUT) :: dnsg(ldim,ldim,max_num_neighbors,nat,nspin)
   !! the derivative of the generalized atomic occupations
   !
   ! ... local variables
   !
   INTEGER :: ibnd, is, na, nt, m1, m2, off1, off2, m11, m22, &
              ldim1, ldim2, eq_na2, na1, na2, nt1, nt2, viz
   COMPLEX(DP), ALLOCATABLE :: dproj1(:,:), dproj2(:,:), dproj_us(:,:)
   INTEGER, EXTERNAL :: find_viz
   !
   CALL start_clock( 'dngdtau' )
   !
#if defined(__CUDA)
   CALL using_evc(0)
   CALL using_evc_d(0)
#endif
   !
   ALLOCATE( dproj1(nwfcU,nb_s:nb_e) )
   ALLOCATE( dproj2(nwfcU,nb_s:nb_e) )
   IF (okvan) ALLOCATE( dproj_us(nwfcU,nb_s:nb_e) )
   !
   !$acc data present_or_copyin(proj,spsi,wfcU) create(dproj1,dproj2,dproj_us)
   !
   ! ... Compute the derivative of the generalized occupation matrices 
   ! ... (the quantities dnsg(m1,m2)) of the atomic orbitals. 
   ! ... They are complex quantities as well as nsg(m1,m2).
   !
   dnsg(:,:,:,:,:) = (0.d0,0.d0)
   !
   ! ... Compute the phases for each atom at this ik
   !
   CALL phase_factor( ik )
   !
   !$acc update self(proj(:,nb_s:nb_e))
   !
   ! ... Compute the USPP contribution to dproj1:
   ! ... <\phi^{at}_{I,m1}|dS/du(alpha,ipol)|\psi_{k,v,s}>
   !
   IF (okvan) THEN
      !$acc data copyin(evc)
      CALL matrix_element_of_dSdtau( alpha, ipol, ik, jkb0, nwfcU, wfcU, nbnd, &
                                     evc, dproj_us, nb_s, nb_e, mykey )
      !$acc end data
   ENDIF
   !
   IF (Hubbard_projectors.EQ."atomic") THEN
      ! ... In the 'atomic' case the calculation must be performed only 
      ! ... once (when na=alpha)
      !
      CALL dprojdtau_k( spsi, alpha, alpha, jkb0, ipol, ik, nb_s, nb_e, &
                        mykey, dproj1 )
      !
      ! ... adds dproj_us to dproj.
      IF ( okvan ) THEN
         !$acc kernels
         dproj1 = dproj1 + dproj_us
         !$acc end kernels
      ENDIF
      !
      !$acc kernels
      dproj2 = dproj1
      !$acc end kernels      
      !
   ELSEIF (Hubbard_projectors.EQ."ortho-atomic") THEN
      ! ... In the 'ortho-atomic' case calculate d[(O^{-1/2})^T]
      ALLOCATE( doverlap_inv(natomwfc,natomwfc) )
      CALL calc_doverlap_inv( alpha, ipol, ik, jkb0 )
   ENDIF
   !$acc data copyin(doverlap_inv)
   !
   ! ... Band parallelization. If each band appears more than once
   ! ... compute its contribution only once (i.e. when mykey=0)
   !
! !omp parallel do default(shared) private(na1,viz,m1,m2,ibnd)
   DO na1 = 1, nat
      nt1 = ityp(na1)
      IF ( is_hubbard(nt1) ) THEN
         ! ... Compute the second contribution to dproj1 due to the derivative of 
         ! ... ortho-atomic orbitals
         IF (Hubbard_projectors.EQ."ortho-atomic") THEN
            CALL dprojdtau_k( spsi, alpha, na1, jkb0, ipol, ik, nb_s, nb_e,&
                              mykey, dproj1 )
            IF ( okvan ) THEN
               !$acc kernels
               dproj1 = dproj1 + dproj_us
               !$acc end kernels
            ENDIF
         ENDIF
         !
         !$acc update self(dproj1)
         !
         ldim1 = ldim_u(nt1)
         DO viz = 1, neighood(na1)%num_neigh
            na2 = neighood(na1)%neigh(viz)
            eq_na2 = at_sc(na2)%at
            nt2 = ityp(eq_na2)
            ldim2 = ldim_u(nt2)
            ! ... Compute the second contribution to dproj2 due to the derivative of 
            ! ... ortho-atomic orbitals
            IF (Hubbard_projectors.EQ."ortho-atomic") THEN
               CALL dprojdtau_k( spsi, alpha, eq_na2, jkb0, ipol, ik, nb_s, &
                                 nb_e, mykey, dproj2 )
               IF ( okvan ) THEN
                  !$acc kernels
                  dproj2 = dproj2 + dproj_us
                  !$acc end kernels
               ENDIF
            ENDIF
            !
            !$acc update self(dproj2)
            !
            IF (mykey==0) THEN
             IF (na1>na2) THEN 
               DO m1 = 1, ldim1
                  DO m2 = 1, ldim2
                     dnsg(m2,m1,viz,na1,current_spin) = &
                     CONJG(dnsg(m1,m2,find_viz(na2,na1),na2,current_spin))
                  ENDDO
               ENDDO
             ELSE
               DO m1 = 1, ldim1
                  off1 = offsetU(na1) + m1
                  IF (m1 > 2*Hubbard_l(nt1)+1) off1 = offsetU_back(na1) + m1 - &
                                                      2*Hubbard_l(nt1) - 1
                  IF (backall(nt1) .AND. m1 > 2*(Hubbard_l(nt1)+Hubbard_l2(nt1)+1) ) &
                     off1 = offsetU_back1(na1) + m1 - 2*(Hubbard_l(nt1)+ &
                                                         Hubbard_l2(nt1)+1)
                  DO m2 = 1, ldim2
                      off2 = offsetU(eq_na2) + m2
                      IF (m2 > 2*Hubbard_l(nt2)+1) off2 = offsetU_back(eq_na2) + &
                                                          m2 - 2*Hubbard_l(nt2) - 1
                      IF (backall(nt2) .AND. m2 > 2*(Hubbard_l(nt2)+      &
                                                     Hubbard_l2(nt2)+1) ) &
                         off2 = offsetU_back1(eq_na2) + m2 - 2*(Hubbard_l(nt2)+ &
                                                                Hubbard_l2(nt2)+1)
                      DO ibnd = nb_s, nb_e
                         dnsg(m2,m1,viz,na1,current_spin) =                 &
                             dnsg(m2,m1,viz,na1,current_spin) +             &
                             wg(ibnd,ik) * DBLE( CONJG(phase_fac(na2)) *    &
                             (proj(off1,ibnd)   * CONJG(dproj2(off2,ibnd)) + &
                              dproj1(off1,ibnd) * CONJG(proj(off2,ibnd)) ) )
                      ENDDO ! ibnd
                  ENDDO ! m2
               ENDDO  ! m1
             ENDIF
            ENDIF
         ENDDO ! viz          
      ENDIF
   ENDDO ! na1
! !omp end parallel do
   !
   !$acc end data
   !$acc end data
   DEALLOCATE( dproj1 )
   DEALLOCATE( dproj2 )
   IF (ALLOCATED(doverlap_inv)) DEALLOCATE( doverlap_inv )
   IF (okvan) DEALLOCATE( dproj_us )
   !
   CALL mp_sum( dnsg, intra_pool_comm )
   !
   ! ... In nspin=1 k-point weight wg is normalized to 2 el/band 
   ! ... in the whole BZ but we are interested in dnsg of one spin component
   !
   IF (nspin == 1) dnsg = 0.5d0 * dnsg
   !
   ! ... Impose hermiticity of dnsg_{m1,m2}
   !
! !omp parallel do default(shared) private(na1,viz,m1,m2)
   DO na1 = 1, nat
      nt1 = ityp (na1)
      IF ( is_hubbard(nt1) ) THEN
         ldim1 = ldim_u(nt1)
         DO viz = 1, neighood(na1)%num_neigh
            na2 = neighood(na1)%neigh(viz)
            IF (na1>na2) THEN
               eq_na2 = at_sc(na2)%at
               nt2 = ityp (eq_na2)
               ldim2 = ldim_u(nt2)
               DO m1 = 1, ldim1
                  DO m2 = 1, ldim2
                     dnsg(m2,m1,viz,na1,current_spin) = &
                         (dnsg(m2,m1,viz,na1,current_spin) + &
                         CONJG(dnsg(m1,m2,find_viz(na2,na1),na2,current_spin)) )*0.5d0
                     dnsg(m1,m2,find_viz(na2,na1),na2,current_spin) = &
                         CONJG(dnsg(m2,m1,viz,na1,current_spin))
                  ENDDO
               ENDDO
            ENDIF
         ENDDO
      ENDIF
   ENDDO
! !omp end parallel do
   !
   CALL stop_clock('dngdtau')
   !
   RETURN
   !
END SUBROUTINE dngdtau_k
!
!
!-----------------------------------------------------------------------------
SUBROUTINE dngdtau_gamma( ldim, rproj, spsi, alpha, jkb0, ipol, ik, nb_s, &
                          nb_e, mykey, dnsg )
   !--------------------------------------------------------------------------
   !! This routine computes the derivative of the nsg (generalized occupation
   !! matrix of the DFT+U+V scheme) with respect to the ionic
   !! displacement \(u(\text{alpha,ipol})\) used to obtain the generalized 
   !! Hubbard contribution to the atomic forces.
   !
   USE kinds,                ONLY : DP
   USE ions_base,            ONLY : nat, ityp
   USE lsda_mod,             ONLY : nspin, current_spin
   USE ldaU,                 ONLY : nwfcU, offsetU, at_sc, offsetU_back, Hubbard_l,&
                                    offsetU_back1, is_Hubbard, Hubbard_l2, backall,&
                                    max_num_neighbors, phase_fac, ldim_u, neighood
   USE wvfct,                ONLY : nbnd, npwx, npw, wg
   USE mp_pools,             ONLY : intra_pool_comm, me_pool, nproc_pool
   USE mp,                   ONLY : mp_sum
   ! 
   IMPLICIT NONE
   !
   INTEGER, INTENT(IN) :: ldim
   !! ldim = 2*Hubbard_lmax+1
   REAL(DP), INTENT(IN) :: rproj(nwfcU,nbnd)
   !! projection
   COMPLEX(DP), INTENT(IN) :: spsi(npwx,nbnd)
   !! \(S\ |\text{evc}\rangle\)
   INTEGER, INTENT(IN) :: alpha
   !! the displaced atom index
   INTEGER, INTENT(IN) :: jkb0
   !! positions of beta functions for atom alpha
   INTEGER, INTENT(IN) :: ipol
   !! the component of displacement
   INTEGER, INTENT(IN) :: ik
   !! k-point index
   INTEGER, INTENT(IN) :: nb_s
   !! starting band number (for band parallelization)
   INTEGER, INTENT(IN) :: nb_e
   !! ending band number (for band parallelization)
   INTEGER, INTENT(IN) :: mykey
   !! If each band appears more than once compute
   !! its contribution only once (i.e. when
   !! \(\text{mykey}=0)\)
   COMPLEX(DP), INTENT(OUT) :: dnsg(ldim,ldim,max_num_neighbors,nat,nspin)
   !! the derivative of the atomic occupations
   !
   ! ... local variables
   !
   INTEGER :: ibnd, is, na, nt, m1, m2, off1, off2, m11, m22, &
              ldim1, ldim2, eq_na2, na1, na2, nt1, nt2, viz
   REAL(DP), ALLOCATABLE :: dproj(:,:)
   INTEGER, EXTERNAL :: find_viz
   !
   CALL start_clock_gpu( 'dngdtau' )
   !
   ALLOCATE( dproj(nwfcU,nb_s:nb_e) )
   !
   !$acc data present_or_copyin(rproj,spsi) create(dproj)
   !
   ! ... Compute the derivative of the generalized occupation matrices 
   ! ... (the quantities dnsg(m1,m2)) of the atomic orbitals. 
   ! ... They are complex quantities as well as nsg(m1,m2).
   !
   CALL dprojdtau_gamma( spsi, alpha, jkb0, ipol, ik, nb_s, nb_e, mykey, dproj )
   !
   !$acc update self(dproj(:,nb_s:nb_e))
   !
   dnsg(:,:,:,:,:) = (0.d0,0.d0)
   !
   ! ... Band parallelization. If each band appears more than once
   ! ... compute its contribution only once (i.e. when mykey=0)
   !
   IF ( mykey/=0 ) GO TO 10
   !
   ! ... Compute the phases for each atom at this ik
   !
   CALL phase_factor( ik )
   !
! !omp parallel do default(shared) private(na1,viz,m1,m2,ibnd)
   DO na1 = 1, nat
      nt1 = ityp(na1)
      IF ( is_hubbard(nt1) ) THEN
         ldim1 = ldim_u(nt1)
         DO viz = 1, neighood(na1)%num_neigh
            na2 = neighood(na1)%neigh(viz)
            eq_na2 = at_sc(na2)%at
            nt2 = ityp(eq_na2)
            ldim2 = ldim_u(nt2)
            IF (na1 > na2) THEN 
               DO m1 = 1, ldim1
                  DO m2 = 1, ldim2
                     dnsg(m2,m1,viz,na1,current_spin) = &
                     CONJG(dnsg(m1,m2,find_viz(na2,na1), na2, current_spin))
                  ENDDO
               ENDDO
            ELSE
               DO m1 = 1, ldim1
                  off1 = offsetU(na1) + m1
                  IF (m1 > 2*Hubbard_l(nt1)+1) off1 = offsetU_back(na1) + m1 - &
                                                      2*Hubbard_l(nt1) - 1
                  IF (backall(nt1) .AND. m1 > 2*(Hubbard_l(nt1)+Hubbard_l2(nt1)+1) ) &
                       off1 = offsetU_back1(na1) + m1 - 2*(Hubbard_l(nt1)+ &
                                                           Hubbard_l2(nt1)+1)
                  DO m2 = 1, ldim2
                     off2 = offsetU(eq_na2) + m2
                     IF (m2 > 2*Hubbard_l(nt2)+1) off2 = offsetU_back(eq_na2) + m2 - &
                                                         2*Hubbard_l(nt2) - 1
                     IF (backall(nt2) .AND. m2 > 2*(Hubbard_l(nt2)+Hubbard_l2(nt2)+1)) &
                         off2 = offsetU_back1(eq_na2) + m2 - 2*(Hubbard_l(nt2)+ &
                                                                Hubbard_l2(nt2)+1)
                     DO ibnd = nb_s, nb_e
                        dnsg(m2,m1,viz,na1,current_spin) =              &
                            dnsg(m2,m1,viz,na1,current_spin) +          &
                            wg(ibnd,ik) * DBLE( CONJG(phase_fac(na2)) * & 
                            (rproj(off1,ibnd) * dproj(off2,ibnd)  +     &
                             dproj(off1,ibnd) * rproj(off2,ibnd) ) )
                     ENDDO ! ibnd
                  ENDDO ! m2
               ENDDO  ! m1
            ENDIF 
         ENDDO ! viz          
      ENDIF 
   ENDDO ! na1
! !omp end parallel do
   !
10 CONTINUE
   !
   !$acc end data
   DEALLOCATE( dproj ) 
   !
   CALL mp_sum( dnsg, intra_pool_comm )
   !
   ! ... In nspin=1 k-point weight wg is normalized to 2 el/band 
   ! ... in the whole BZ but we are interested in dnsg of one spin component
   !
   IF (nspin == 1) dnsg = 0.5d0 * dnsg
   !
   ! ... Impose hermiticity of dnsg_{m1,m2}
   !
! !omp parallel do default(shared) private(na1,viz,m1,m2)
   DO na1 = 1, nat
      nt1 = ityp(na1)
      IF ( is_hubbard(nt1) ) THEN
         ldim1 = ldim_u(nt1)
         DO viz = 1, neighood(na1)%num_neigh
            na2 = neighood(na1)%neigh(viz)
            IF (na1 > na2) THEN
               eq_na2 = at_sc(na2)%at
               nt2 = ityp (eq_na2)
               ldim2 = ldim_u(nt2)
               DO m1 = 1, ldim1
                  DO m2 = 1, ldim2
                     dnsg(m2,m1,viz,na1,current_spin) = &
                         (dnsg(m2,m1,viz,na1,current_spin) + &
                         CONJG(dnsg(m1,m2,find_viz(na2,na1),na2,current_spin)) )*0.5d0
                     dnsg(m1,m2,find_viz(na2,na1),na2,current_spin) =  &
                         CONJG(dnsg(m2,m1,viz,na1,current_spin))
                  ENDDO
               ENDDO
            ENDIF
         ENDDO
      ENDIF
   ENDDO
! !omp end parallel do
   !
   CALL stop_clock_gpu( 'dngdtau' )
   !
   RETURN
   !
END SUBROUTINE dngdtau_gamma
!
!
!------------------------------------------------------------------------------
SUBROUTINE dprojdtau_k( spsi, alpha, na, ijkb0, ipol, ik, nb_s, nb_e, mykey, dproj )
   !-----------------------------------------------------------------------------
   !! This routine computes the first derivative of the projection
   !! \(\langle\phi^{at}_{I,m1}|S|\psi_{k,v,s}\rangle\) with respect to 
   !! the atomic displacement \(u(\text{alpha,ipol})\). We remind that:
   !! $$ \text{ns}_{I,s,m1,m2} = \sum_{k,v}
   !!    f_{kv} \langle\phi^{at}_{I,m1}|S|\psi_{k,v,s}\rangle
   !!           \langle\psi_{k,v,s}|S|\phi^{at}_{I,m2}\rangle $$
   !
   USE kinds,                ONLY : DP
   USE ions_base,            ONLY : nat, ntyp => nsp, ityp
   USE cell_base,            ONLY : tpiba
   USE gvect,                ONLY : g
   USE klist,                ONLY : nks, xk, ngk, igk_k
   USE ldaU,                 ONLY : nwfcU, wfcU, offsetU, is_hubbard_back,   &
                                    Hubbard_l2, offsetU_back, offsetU_back1, &
                                    ldim_u, backall, lda_plus_u_kind, Hubbard_l,&
                                    Hubbard_projectors, oatwfc, is_Hubbard
   USE wvfct,                ONLY : nbnd, npwx, wg
   USE uspp,                 ONLY : okvan, nkb
   USE uspp_param,           ONLY : nh
   USE basis,                ONLY : natomwfc, wfcatom
   USE force_mod,            ONLY : overlap_inv, doverlap_inv
   USE mp_bands,             ONLY : intra_bgrp_comm
   USE mp,                   ONLY : mp_sum
   !
   IMPLICIT NONE
   !
   COMPLEX(DP), INTENT(IN) :: spsi(npwx,nbnd)
   !! \(S\ |\text{evc}\rangle\)
   INTEGER, INTENT(IN) :: alpha
   !! the displaced atom
   INTEGER, INTENT(IN) :: na
   !! the atom for which the force is computed
   INTEGER, INTENT(IN) :: ijkb0
   !! position of beta functions for atom alpha
   INTEGER, INTENT(IN) :: ipol
   !! the component of displacement
   INTEGER, INTENT(IN) :: ik
   !! k-point index
   INTEGER, INTENT(IN) :: nb_s
   !! starting band number (for band parallelization)
   INTEGER, INTENT(IN) :: nb_e
   !! ending band number (for band parallelization)
   INTEGER, INTENT(IN) :: mykey
   !! If each band appears more than once compute
   !! its contribution only once (i.e. when
   !! \(\text{mykey}=0)\)
   COMPLEX(DP), INTENT(OUT) :: dproj(nwfcU,nb_s:nb_e)
   !! derivative of projection
   !
   ! ... local variables
   !
   INTEGER :: npw, nt, ig, m1, m2, m3, ibnd, iwf, nt_, ih, jh, ldim, &
              ldim_std, offpm, i, j, m_start, m_end
   REAL(DP) :: gvec, xki
   INTEGER :: nh_nt
   COMPLEX(DP), ALLOCATABLE :: dwfc(:,:), &
                               dproj0(:,:) !derivative of the projector
   !
   CALL start_clock_gpu( 'dprojdtau' )
   !
   !$acc data present_or_copyin(spsi,dproj)
   !
   nt  = ityp(na)
   npw = ngk(ik)
   ldim = ldim_u(nt)
   ldim_std = 2*Hubbard_l(nt)+1
   xki = xk(ipol,ik)
   nh_nt = nh(nt)
   !
   !$acc kernels
   dproj = (0.d0,0.d0)
   !$acc end kernels
   !
   IF ((Hubbard_projectors.EQ."atomic") .AND. (na==alpha) .AND. &
       (is_hubbard(nt).OR.is_hubbard_back(nt))) THEN
      !
      !********************* ATOMIC CASE *******************************
      !
      ! ... Compute the derivative of the atomic wfc 'na' when displacing atom 'alpha'. 
      ! ... Note, this derivative is different from zero only when na=alpha, i.e. when 
      ! ... the displaced atom is the Hubbard atom itself (this is so due to the 
      ! ... localized nature of atomic wfc).
      ! ... Note: parallelization here is over plane waves, not over bands!
      !
      ALLOCATE( dwfc(npwx,ldim) )
      !$acc data create(dwfc)
      !
      !$acc kernels
      dwfc = (0.d0,0.d0)
      !$acc end kernels
      !
      ! ... DFT+U: In the expression of dwfc we don't need (k+G) but just G; k always
      ! ... multiplies the underived quantity and gives an opposite contribution
      ! ... in c.c. term because the sign of the imaginary unit.
      ! ... DFT+U+V: the k-point coordinate is needed, i.e. (k+G) instead of just G.
      !
      DO m1 = 1, ldim
         IF (m1 <= ldim_std) THEN
            offpm = offsetU(alpha) + m1
         ELSE
            offpm = offsetU_back(alpha) + m1 - ldim_std
            IF (backall(nt) .AND. m1 > ldim_std+2*Hubbard_l2(nt)+1) &
                 offpm = offsetU_back1(alpha)+m1-ldim_std-2*Hubbard_l2(nt)-1
         ENDIF
         !$acc parallel loop
         DO ig = 1, npw
            IF (lda_plus_u_kind==0) THEN
               gvec = g(ipol,igk_k(ig,ik)) * tpiba
            ELSEIF (lda_plus_u_kind==2) THEN
               gvec = (g(ipol,igk_k(ig,ik)) + xki) * tpiba
            ENDIF
            dwfc(ig,m1) = (0.d0,-1.d0) * gvec * wfcU(ig,offpm)
         ENDDO
         !
      ENDDO
! !omp end parallel do
      !
      ALLOCATE ( dproj0(ldim,nbnd) )
      !$acc data create(dproj0)
      !$acc host_data use_device(dwfc,spsi,dproj0)
      CALL MYZGEMM( 'C','N',ldim, nbnd, npw, (1.d0,0.d0), &
                    dwfc, npwx, spsi, npwx, (0.d0,0.d0),  &
                    dproj0, ldim )
      CALL mp_sum( dproj0, intra_bgrp_comm )
      !$acc end host_data
      !
      ! ... Copy to dproj results for the bands treated by this processor.
      !
      DO m1 = 1, ldim
         IF (m1 <= ldim_std ) THEN
            offpm = offsetU(na)+m1
         ELSE
            offpm = offsetU_back(alpha) + m1 - ldim_std
            IF (backall(nt) .AND. m1 > ldim_std+2*Hubbard_l2(nt)+1) &
              offpm = offsetU_back1(alpha) + m1 - ldim_std - 2*Hubbard_l2(nt) - 1
         ENDIF
         !
         !$acc parallel loop
         DO ibnd = nb_s, nb_e
            dproj(offpm,ibnd) = dproj0(m1,ibnd)
         ENDDO
      ENDDO
      !
      !$acc end data
      !$acc end data
      DEALLOCATE( dwfc, dproj0 )
      !
   ELSEIF (Hubbard_projectors.EQ."ortho-atomic") THEN
      !
      !***************** ORTHO-ATOMIC CASE ***********************************
      !
      ! ... Compute the derivative of the ortho-atomic wfc 'na' when displacing atom
      ! ... 'alpha'. 
      ! ... Note, this derivative is different from zero not only when na=alpha but also 
      ! ... when na/=alpha, i.e. when we displace a non-Hubbard atom this will give a
      ! ... non-zero contribution to the derivative of the ortho-atomic wfc na. This 
      ! ... is so due to the definition of the ortho-atomic wfc:
      ! ... \phi_ortho_I = \sum_J O^{-1/2}_JI \phi_J
      ! ... Note: parallelization here is over plane waves, not over bands!
      !
      IF (is_hubbard_back(nt)) CALL errore( "dprojdtau_k", &
                 " Forces with background and  ortho-atomic are not supported", 1 )
      !
      ALLOCATE( dwfc(npwx,ldim) )
      !$acc data create(dwfc) present_or_copyin(wfcatom,overlap_inv)
      !
      !$acc kernels
      dwfc(:,:) = (0.d0,0.d0)
      !$acc end kernels
      !
      ! ... Determine how many atomic wafefunctions there are for atom 'alpha'
      ! ... and determine their position in the list of all atomic 
      ! ... wavefunctions of all atoms.
      CALL natomwfc_per_atom( alpha, m_start, m_end )
      !
      ! ... 1. Derivative of the atomic wavefunctions (the only one which
      ! ...    is different from zero) times O^-0.5 transposed.
      ! ...    NOTE: overlap_inv is already transposed (it is O^{-1/2}_JI),
      ! ...         hence we obtain \sum_J O^{-1/2}_JI \dphi_J/d\tau(alpha,ipol)  
      !
#if defined(__XLF)
      ! IBM XL 16.1.1 gives INTERNAL COMPILER ERROR
      CALL errore( 'dprojdtau_k', 'disabled when it is compiled by xlf.', 1 )
#else
      offpm = oatwfc(na) ! offset
      !
      !$acc parallel loop
      DO ig = 1, npw
         gvec = (g(ipol,igk_k(ig,ik)) + xki) * tpiba
         DO m1 = 1, ldim
            DO m2 = m_start, m_end
               dwfc(ig,m1) = dwfc(ig,m1) + (0.d0,-1.d0) * gvec * &
                             overlap_inv(offpm+m1,m2) * wfcatom(ig,m2)
            ENDDO
         ENDDO
      ENDDO
#endif
      !
      ! ... 2. Contribution due to the derivative of (O^{-1/2})_JI which
      ! ...    is multiplied by atomic wavefunctions
      !
      ! ... Now compute \sum_J dO^{-1/2}_JI/d\tau(alpha,ipol) \phi_J
      ! ... and add it to another term (see above).
      ! ... Note, doverlap_inv is d(O^{-1/2}) not transposed. The transposition 
      ! ... of d(O^{-1/2}) is taken into account via a proper usage of the order
      ! ... of indices in doverlap_inv: 
      ! ... dwfc(ig,m1) = dwfc(ig,m1) + wfcatom(ig,m2) * doverlap_inv(m2,offpm+m1)
      ! ... where m1=1,ldim; m2=1,natomwfc; ig=1,npw
      !
      !$acc data present_or_copyin(doverlap_inv)
      !$acc host_data use_device(wfcatom,doverlap_inv,dwfc)
      CALL MYZGEMM( 'N','N', npw, ldim, natomwfc, (1.d0,0.d0), &
                    wfcatom, npwx, doverlap_inv(:,offpm+1:offpm+ldim), &
                    natomwfc, (1.d0,0.d0), dwfc, npwx )
      !$acc end host_data
      !$acc end data
      !
      ! ... 3. Final step: compute dproj0 = <dwfc|spsi>
      !
      ALLOCATE( dproj0(ldim,nbnd) )
      !$acc data create(dproj0)
      !
      !$acc host_data use_device(dwfc,spsi,dproj0)
      CALL MYZGEMM( 'C','N',ldim, nbnd, npw, (1.d0,0.d0), &
                    dwfc, npwx, spsi, npwx,  (0.d0,0.d0), &
                    dproj0, ldim )         
      CALL mp_sum( dproj0, intra_bgrp_comm )
      !$acc end host_data
      !
      ! ... Copy to dproj results for the bands treated by this processor
      !
      offpm = offsetU(na)
      IF (mykey==0) THEN
         !$acc parallel loop collapse(2)
         DO ibnd = nb_s, nb_e
            DO m1 = 1, ldim
               dproj(offpm+m1,ibnd) = dproj0(m1,ibnd)
            ENDDO
         ENDDO
      ENDIF
      !
      !$acc end data
      !$acc end data
      DEALLOCATE( dproj0 )
      DEALLOCATE( dwfc )
      !
   ENDIF
   !
   !$acc end data
   !
   CALL stop_clock_gpu( 'dprojdtau' )
   !
   RETURN
   !
END SUBROUTINE dprojdtau_k
!
!------------------------------------------------------------------------
SUBROUTINE natomwfc_per_atom( alpha, m_start, m_end )
   !-----------------------------------------------------------------------
   !! This routine determines the starting (m_start) and the last (m_end)
   !! index for all atomic wavefunctions of a given atom 'alpha'
   !! when referring to the total list of all atomic wavefunctions of all atoms.
   !
   USE ions_base,    ONLY : nat, ityp
   USE uspp_param,   ONLY : upf
   USE ldaU,         ONLY : Hubbard_l
   USE io_global,    ONLY : stdout
   !
   IMPLICIT NONE
   !
   INTEGER, INTENT(IN)  :: alpha
   INTEGER, INTENT(OUT) :: m_start
   INTEGER, INTENT(OUT) :: m_end
   !
   ! ... local variables
   !
   INTEGER :: counter, l, na, nt, nb
   !
   counter = 0
   m_start = 0
   m_end   = 0
   DO na = 1, nat
      IF (na == alpha) m_start = counter + 1
      nt = ityp(na)
      DO nb = 1, upf(nt)%nwfc
         IF (upf(nt)%oc(nb) >= 0.d0) THEN
            l = upf(nt)%lchi(nb)
            counter = counter + 2*l + 1
         ENDIF
      ENDDO
      IF (na == alpha) THEN
         m_end = counter
         GO TO 11
      ENDIF
   ENDDO
   !
11 CONTINUE
   !
   IF (m_start==0 .OR. m_end==0) CALL errore("natomwfc_per_atom", &
                                   "m_start=0 or m_end=0",1)
   IF (m_start > m_end) CALL errore("natomwfc_per_atom", &
                                   "m_start > m_end",1)
   !
   RETURN
   !
END SUBROUTINE natomwfc_per_atom
!
!--------------------------------------------------------------------
SUBROUTINE calc_doverlap_inv( alpha, ipol, ik, ijkb0 )
   !-----------------------------------------------------------------
   !! This routine computes the derivative of \(O^{-1/2}\) transposed.
   !
   USE kinds,            ONLY : DP
   USE cell_base,        ONLY : tpiba
   USE gvect,            ONLY : g
   USE uspp,             ONLY : okvan
   USE klist,            ONLY : xk, ngk, igk_k
   USE basis,            ONLY : natomwfc, wfcatom, swfcatom
   USE force_mod,        ONLY : eigenval, eigenvect, overlap_inv, doverlap_inv
   USE ldaU,             ONLY : Hubbard_projectors
   USE mp_bands,         ONLY : intra_bgrp_comm
   USE mp,               ONLY : mp_sum
   !
   IMPLICIT NONE
   !
   INTEGER, INTENT(IN) :: alpha
   !! the displaced atom
   INTEGER, INTENT(IN) :: ipol
   !! the component of displacement
   INTEGER, INTENT(IN) :: ik
   !! k-point index
   INTEGER, INTENT(IN) :: ijkb0
   !! position of beta functions for atom alpha
   !
   ! ... local variables
   !
   INTEGER :: ig, m1, m2, npw, m_start, m_end
   REAL(DP) :: gvec, xki
   COMPLEX(DP) :: temp
   COMPLEX(DP), ALLOCATABLE :: doverlap(:,:), doverlap_us(:,:)
   ! derivative of the overlap matrix  
   !
   CALL start_clock( 'calc_doverlap_inv' )
   !
   IF (Hubbard_projectors.NE."ortho-atomic") RETURN
   !
   xki = xk(ipol,ik)
   !
   ALLOCATE( doverlap(natomwfc,natomwfc) )
   !
   !$acc data present_or_copyin(wfcatom,swfcatom,eigenval) &
   !$acc&          create(doverlap_inv,eigenvect)
   !
   !$acc kernels
   doverlap_inv(:,:) = (0.0d0,0.0d0)
   !$acc end kernels
   doverlap(:,:) = (0.0d0,0.0d0)
   !
   npw = ngk(ik)
   !
   ! ... Determine how many atomic wafefunctions there are for atom 'alpha'
   ! ... and determine their position in the list of all atomic 
   ! ... wavefunctions of all atoms
   CALL natomwfc_per_atom( alpha, m_start, m_end )
   !
   ! ... Compute the derivative dO_IJ/d\tau(alpha,ipol)
   ! ... Calculate < dphi_I/d\tau(alpha,ipol) | S | phi_J >
   DO m1 = m_start, m_end
      DO m2 = 1, natomwfc
         temp = (0.d0,0.d0)
         !$acc parallel loop reduction(+:temp)
         DO ig = 1, npw
            ! ... (k+G) * 2pi/a
            gvec = (g(ipol,igk_k(ig,ik)) + xki) * tpiba
            temp = temp + (0.d0,1.d0) * gvec * CONJG(wfcatom(ig,m1)) *&
                          swfcatom(ig,m2)
         ENDDO
         doverlap(m1,m2) = temp
      ENDDO
   ENDDO
   ! ... Calculate < phi_I | S | dphi_J/d\tau(alpha,ipol) >
   DO m1 = 1, natomwfc
      DO m2 = m_start, m_end
         temp = (0.d0,0.d0)
         !$acc parallel loop reduction(+:temp)
         DO ig = 1, npw
            ! ... (k+G) * 2pi/a
            gvec = (g(ipol,igk_k(ig,ik)) + xki) * tpiba
            temp = temp + (0.d0,-1.d0) * gvec * CONJG(swfcatom(ig,m1)) *&
                          wfcatom(ig,m2)
         ENDDO
         doverlap(m1,m2) = doverlap(m1,m2) + temp
      ENDDO
   ENDDO
   !
   ! ... Sum over G vectors
   CALL mp_sum( doverlap, intra_bgrp_comm )
   !
   !$acc data copyin(doverlap)
   !
   ! ... Add the USPP term in dO_IJ/d\tau(alpha,ipol):
   ! ... < phi_I | dS/d\tau(alpha,ipol) | phi_J >
   !
   IF (okvan) THEN
      ! ... Calculate doverlap_us = < phi_I | dS/d\tau(alpha,ipol) | phi_J >
      ALLOCATE( doverlap_us(natomwfc,natomwfc) )
      !$acc data create(doverlap_us)
      CALL matrix_element_of_dSdtau( alpha, ipol, ik, ijkb0, natomwfc, &
                                     wfcatom, natomwfc, wfcatom,       &
                                     doverlap_us, 1, natomwfc, 0 )
      !$acc kernels
      doverlap(:,:) = doverlap(:,:) + doverlap_us(:,:)
      !$acc end kernels
      !$acc end data 
      DEALLOCATE( doverlap_us )
   ENDIF
   !
   ! ... Now compute dO^{-1/2}_JI/d\tau(alpha,ipol) using dO_IJ/d\tau(alpha,ipol)
   ! ... Note the transposition!
   !
   !$acc update device(eigenvect)
   !
#if defined(__CUDA)
   !$acc host_data use_device(eigenval,eigenvect,doverlap,doverlap_inv)
   CALL calculate_doverlap_inv_gpu( natomwfc, eigenval, eigenvect, &
                                    doverlap, doverlap_inv )
   !$acc end host_data
#else
   CALL calculate_doverlap_inv( natomwfc, eigenval, eigenvect, &
                                doverlap, doverlap_inv )
#endif
   !
   !$acc update self(doverlap_inv)
   !
   !$acc end data
   !$acc end data
   DEALLOCATE( doverlap )
   !
END SUBROUTINE calc_doverlap_inv
!
!
!----------------------------------------------------------------------
SUBROUTINE matrix_element_of_dSdtau( alpha, ipol, ik, ijkb0, lA, A, &
                                     lB, B, A_dS_B, lB_s, lB_e, mykey )
   !--------------------------------------------------------------------
   !! This routine computes the matrix element \(\langle A | 
   !! dS/d\tau(\alpha,\text{ipol}) | B \rangle\).  
   !! Written by I. Timrov (2020).
   !
   USE kinds,                ONLY : DP
   USE ions_base,            ONLY : nat, ntyp => nsp, ityp
   USE cell_base,            ONLY : tpiba
   USE wvfct,                ONLY : npwx, wg
   USE uspp,                 ONLY : nkb, okvan, vkb, qq_at
   USE uspp_param,           ONLY : nh
   USE klist,                ONLY : igk_k, ngk
   USE becmod,               ONLY : calbec
   USE becmod_subs_gpum,     ONLY : calbec_gpu
   USE gvect,                ONLY : g
   !
   IMPLICIT NONE
   !
   INTEGER, INTENT(IN) :: alpha
   !! the displaced atom
   INTEGER, INTENT(IN) :: ipol
   !! the component of displacement
   INTEGER, INTENT(IN) :: ik
   !! the k point
   INTEGER, INTENT(IN) :: ijkb0
   !! position of beta functions for atom alpha 
   INTEGER, INTENT(IN) :: lA
   INTEGER, INTENT(IN) :: lB
   !! There is a possibility to parallelize over lB
   INTEGER, INTENT(IN) :: lB_s
   !! lB start
   INTEGER, INTENT(IN) :: lB_e
   !! lB end
   COMPLEX(DP), INTENT(IN)  :: A(npwx,lA)
   COMPLEX(DP), INTENT(IN)  :: B(npwx,lB)
   COMPLEX(DP), INTENT(OUT) :: A_dS_B(lA,lB_s:lB_e)
   INTEGER, INTENT(IN) :: mykey
   !
   ! ... local variables
   !
   INTEGER :: npw, nt, ih, jh, ig, iA, iB, nh_nt
   REAL(DP) :: gvec
   COMPLEX(DP), ALLOCATABLE :: Adbeta(:,:), Abeta(:,:), dbetaB(:,:), &
                               betaB(:,:), aux(:,:), qq(:,:)
   !
   A_dS_B(:,:) = (0.0d0, 0.0d0)
   !
   IF (.NOT.okvan) RETURN
   !
   !$acc data present_or_copyin(A,B) present_or_copyout(A_dS_B)
   !
   nt = ityp(alpha)
   npw = ngk(ik)
   nh_nt = nh(nt)
   !
   ALLOCATE( Adbeta(lA,nh(nt)) )
   ALLOCATE( Abeta(lA,nh(nt))  )
   ALLOCATE( dbetaB(nh(nt),lB) )
   ALLOCATE( betaB(nh(nt),lB)  )
   ALLOCATE( qq(nh(nt),nh(nt)) )
   !$acc data create(Adbeta,Abeta,dbetaB,betaB,qq)
   !
   !$acc parallel loop collapse(2) present(qq_at)
   DO jh = 1, nh_nt
      DO ih = 1, nh_nt
         qq(ih,jh) = CMPLX(qq_at(ih,jh,alpha), 0.0d0, kind=DP)
      ENDDO
   ENDDO
   !
   ! ... aux is used as a workspace
   ALLOCATE( aux(npwx,nh(nt)) )
   !$acc data create(aux)
   !
   ! ... Beta function
! !omp parallel do default(shared) private(ig,ih)
   !$acc parallel loop collapse(2) present(vkb(:,:))
   DO ih = 1, nh_nt
      DO ig = 1, npw
         aux(ig,ih) = vkb(ig,ijkb0+ih)
      ENDDO
   ENDDO
   !$acc parallel loop collapse(2) 
   DO ih = 1, nh_nt
      DO ig = npw+1, npwx
         aux(ig,ih) = (0.0d0, 0.0d0)
      ENDDO
   ENDDO
! !omp end parallel do
   !
#if defined(__CUDA)
   !$acc host_data use_device(A,Abeta,B,betaB,aux)
   CALL calbec_gpu( npw, A, aux, Abeta )
   CALL calbec_gpu( npw, aux, B, betaB )
   !$acc end host_data
#else
   ! ... Calculate Abeta = <A|beta>
   CALL calbec( npw, A, aux, Abeta )
   ! ... Calculate betaB = <beta|B>
   CALL calbec( npw, aux, B, betaB )
#endif
   !
   ! ... Calculate the derivative of the beta function
! !omp parallel do default(shared) private(ig,ih)
   !
   !$acc parallel loop
   DO ih = 1, nh_nt
      DO ig = 1, npw
         gvec = g(ipol,igk_k(ig,ik)) * tpiba
         aux(ig,ih) = (0.d0,-1.d0) * aux(ig,ih) * gvec
      ENDDO
   ENDDO
! !omp end parallel do
   !
#if defined(__CUDA)
   !$acc host_data use_device(A,Adbeta,B,dbetaB,aux)
   CALL calbec_gpu( npw, A, aux, Adbeta )
   CALL calbec_gpu( npw, aux, B, dbetaB )
   !$acc end host_data
#else
   ! ... Calculate Abeta = <A|beta>
   CALL calbec( npw, A, aux, Adbeta )
   ! ... Calculate betaB = <beta|B>
   CALL calbec( npw, aux, B, dbetaB )
#endif
   !$acc end data
   DEALLOCATE( aux )
   ALLOCATE( aux(nh(nt),lB) )
   !$acc data create(aux)
   !
   ! ... Calculate \sum_jh qq_at(ih,jh) * dbetaB(jh)
   !$acc host_data use_device(qq,dbetaB,aux)
   CALL MYZGEMM( 'N', 'N', nh(nt), lB_e-lB_s+1, nh(nt), (1.0d0,0.0d0), &
                 qq, nh(nt), dbetaB(1,lB_s),    nh(nt), (0.0d0,0.0d0), &
                 aux(1,lB_s), nh(nt) )
   !$acc end host_data
   !$acc kernels
   dbetaB(:,:) = aux(:,:)
   !$acc end kernels
   !
   ! ... Calculate \sum_jh qq_at(ih,jh) * betaB(jh)
   !$acc host_data use_device(qq,betaB,aux)
   CALL MYZGEMM( 'N', 'N', nh(nt), lB_e-lB_s+1, nh(nt), (1.0d0,0.0d0), &
                 qq, nh(nt), betaB(1,lB_s),     nh(nt), (0.0d0,0.0d0), &
                 aux(1,lB_s), nh(nt) )
   !$acc end host_data
   !$acc kernels
   betaB(:,:) = aux(:,:)
   !$acc end kernels
   !
   !$acc end data
   DEALLOCATE( aux )
   !
   ! ... A_dS_B(iA,iB) = \sum_ih [Adbeta(iA,ih) * betaB(ih,iB) +
   ! ...                          Abeta(iA,ih)  * dbetaB(ih,iB)] 
   ! ... Only A_dS_B(:,lB_s:lB_e) are calculated
   !
   IF ( mykey == 0 ) THEN
      !$acc host_data use_device(Adbeta,betaB,Abeta,dbetaB,A_dS_B)
      CALL MYZGEMM( 'N', 'N', lA, lB_e-lB_s+1, nh(nt), (1.0d0,0.0d0), &
                    Adbeta, lA, betaB(1,lB_s), nh(nt), (0.0d0,0.0d0), &
                    A_dS_B(1,lB_s), lA )
      CALL MYZGEMM( 'N', 'N', lA, lB_e-lB_s+1, nh(nt), (1.0d0,0.0d0), &
                    Abeta, lA, dbetaB(1,lB_s), nh(nt), (1.0d0,0.0d0), &
                    A_dS_B(1,lB_s), lA )
      !$acc end host_data
   ENDIF
   !
   !$acc end data
   DEALLOCATE( Abeta  )
   DEALLOCATE( Adbeta )
   DEALLOCATE( dbetaB )
   DEALLOCATE( betaB  )
   DEALLOCATE( qq     )
   !
   !$acc end data
   !
   RETURN
   !
END SUBROUTINE matrix_element_of_dSdtau
!
!
!-----------------------------------------------------------------------
SUBROUTINE dprojdtau_gamma( spsi, alpha, ijkb0, ipol, ik, nb_s, nb_e, &
                            mykey, dproj )
   !-----------------------------------------------------------------------
   !! This routine is the gamma version of \(\texttt{dprojdtau_k}\).
   !! It computes the first derivative of the projection
   !! \(\langle\phi^{at}_{I,m1}|S|\psi_{k,v,s}\rangle\) with respect to 
   !! the atomic displacement \(u(\text{alpha,ipol})\). We remind that:
   !! $$ \text{ns}_{I,s,m1,m2} = \sum_{k,v}
   !!    f_{kv} \langle\phi^{at}_{I,m1}|S|\psi_{k,v,s}\rangle
   !!           \langle\psi_{k,v,s}|S|\phi^{at}_{I,m2}\rangle $$
   !
   USE kinds,                ONLY : DP
   USE ions_base,            ONLY : nat, ntyp => nsp, ityp
   USE cell_base,            ONLY : tpiba
   USE gvect,                ONLY : g
   USE klist,                ONLY : nks, xk, ngk, igk_k
   USE ldaU,                 ONLY : is_hubbard, Hubbard_l, nwfcU, wfcU, offsetU, &
                                    is_hubbard_back, Hubbard_l2, offsetU_back,   &
                                    offsetU_back1, ldim_u, backall, Hubbard_projectors
   USE wvfct,                ONLY : nbnd, npwx,  wg
   USE uspp,                 ONLY : nkb, vkb, qq_at
   USE uspp_param,           ONLY : nh
   USE wavefunctions,        ONLY : evc
   USE becmod,               ONLY : calbec
   USE becmod_gpum,          ONLY : bec_type_d, becp_d
   USE becmod_subs_gpum,     ONLY : calbec_gpu
   USE wavefunctions,        ONLY : evc
   USE wavefunctions_gpum,   ONLY : using_evc, using_evc_d, evc_d
   USE mp_bands,             ONLY : intra_bgrp_comm
   USE mp_pools,             ONLY : intra_pool_comm, me_pool, nproc_pool
   USE mp,                   ONLY : mp_sum
   !
   IMPLICIT NONE
   !
   COMPLEX(DP), INTENT(IN) :: spsi(npwx,nbnd)
   !! \(S\ |\text{evc}\rangle\)
   INTEGER, INTENT(IN) :: alpha
   !! the displaced atom
   INTEGER, INTENT(IN) :: ijkb0
   !! position of beta functions for atom alpha
   INTEGER, INTENT(IN) :: ipol
   !! the component of displacement
   INTEGER, INTENT(IN) :: ik
   !! k-point index
   INTEGER, INTENT(IN) :: nb_s
   !! starting band number (for band parallelization)
   INTEGER, INTENT(IN) :: nb_e
   !! ending band number (for band parallelization)
   INTEGER, INTENT(IN) :: mykey
   !! If each band appears more than once
   !! compute its contribution only once (i.e. when mykey=0)
   REAL(DP), INTENT(OUT) :: dproj(nwfcU,nb_s:nb_e)
   !! derivative of projection
   !
   ! ... local variables
   !
   INTEGER :: npw, nt, ig, na_, m1, ibnd, iwf, nt_, ih, jh, ldim, &
              ldim_std, offpm, nh_nt
   REAL(DP) :: gvec
   COMPLEX(DP) :: bpsi_ii
   !
   REAL(DP), ALLOCATABLE :: dproj0(:,:)
   COMPLEX(DP), ALLOCATABLE :: dwfc(:,:)
   COMPLEX(DP), ALLOCATABLE :: dbeta(:,:)
   REAL(DP), ALLOCATABLE :: betapsi(:,:), dbetapsi(:,:), wfatbeta(:,:), &
                            wfatdbeta(:,:), bproj(:,:), betapsi0(:,:)
   !      dwfc(npwx,ldim),       ! the derivative of the atomic wavefunction
   !      dbeta(npwx,nhm),       ! the derivative of the beta function
   !      betapsi(nhm,nbnd),     ! <beta|evc>
   !      dbetapsi(nhm,nbnd),    ! <dbeta|evc>
   !      wfatbeta(nwfcU,nhm),   ! <wfcU|beta>
   !      wfatdbeta(nwfcU,nhm)   ! <wfcU|dbeta>
   !
   ! See the implementation in dprojdtau_k
   !
   IF (Hubbard_projectors.EQ."ortho-atomic") CALL errore( "dprojdtau_gamma", &
                " Forces with gamma-only and ortho-atomic are not supported", 1 )
   !
   CALL start_clock_gpu( 'dprojdtau' )
   !
   !$acc data present_or_copyin(dproj,spsi,wfcU)
   !
   nt = ityp(alpha)
   npw = ngk(ik)
   ldim = ldim_u(nt)
   ldim_std = 2*Hubbard_l(nt)+1
   nh_nt = nh(nt)
   !
   !$acc kernels
   dproj(:,:) = 0.0_DP
   !$acc end kernels
   !
   ! ... First the derivatives of the atomic wfc and the beta are computed
   ! ... Note: parallelization here is over plane waves, not over bands!
   !
   IF ( is_hubbard(nt) .OR. is_hubbard_back(nt) ) THEN
      !      
      ALLOCATE( dproj0(ldim,nbnd) )
      ALLOCATE( dwfc(npwx,ldim) )
      !$acc data create(dwfc,dproj0)
      !
      ! ... In the expression of dwfc we don't need (k+G) but just G; k always
      ! ... multiplies the underived quantity and gives an opposite contribution
      ! ... in c.c. term because the sign of the imaginary unit. But in any case,
      ! ... here we consider the situation when k = 0.
      !
      DO m1 = 1, ldim
        IF (m1 <= ldim_std) THEN
           offpm = offsetU(alpha) + m1
        ELSE
           offpm = offsetU_back(alpha) + m1 - ldim_std 
           IF (backall(nt) .AND. m1 > ldim_std+2*Hubbard_l2(nt)+1) &
              offpm = offsetU_back1(alpha) + m1 - ldim_std - 2*Hubbard_l2(nt) - 1
        ENDIF
        !$acc parallel loop
        DO ig = 1, npwx
            gvec = g(ipol,igk_k(ig,ik)) * tpiba
            IF (ig<=npw) dwfc(ig,m1) = (0.d0,-1.d0) * gvec * wfcU(ig,offpm)
            IF (ig> npw) dwfc(ig,m1) = (0.d0,0.d0)
        ENDDO
        !
      ENDDO
! !omp end parallel do
      !
      ! ... there is no G=0 term
      !$acc host_data use_device(spsi,dwfc,dproj0)
      CALL MYDGEMM( 'T','N',ldim, nbnd, 2*npw, 2.0_DP, dwfc, 2*npwx, spsi, &
                    2*npwx, 0.0_DP, dproj0, ldim )
      CALL mp_sum( dproj0, intra_bgrp_comm )
      !$acc end host_data
      !
      ! ... copy to dproj results for the bands treated by this processor
      !
      DO m1 = 1, ldim
         IF (m1<=ldim_std) THEN
            offpm = offsetU(alpha) + m1
         ELSE
            offpm = offsetU_back(alpha) + m1 - ldim_std
            IF (backall(nt) .AND. m1 > ldim_std+2*Hubbard_l2(nt)+1) &
               offpm = offsetU_back1(alpha)+m1-ldim_std-2*Hubbard_l2(nt)-1
         ENDIF
         !$acc parallel loop
         DO ibnd = nb_s, nb_e
            dproj(offpm,ibnd) = dproj0(m1,ibnd)
         ENDDO
      ENDDO
      !
      offpm = offsetU(alpha)
      !$acc parallel loop collapse(2)
      DO ibnd = nb_s, nb_e
         DO m1 = 1, ldim
            dproj(m1+offpm,ibnd) = dproj0(m1,ibnd)
         ENDDO
      ENDDO
      !
      !$acc end data
      DEALLOCATE( dwfc, dproj0 ) 
      !
   ENDIF
   !
   ALLOCATE( betapsi0(nh(nt),nbnd)   )
   ALLOCATE( dbetapsi(nh(nt),nbnd)   ) 
   ALLOCATE( wfatdbeta(nwfcU,nh(nt)) )
   ALLOCATE( wfatbeta(nwfcU,nh(nt))  )
   ALLOCATE( dbeta(npwx,nh(nt))      )
   !$acc data create(betapsi0,dbetapsi,wfatdbeta,wfatbeta)
   !$acc data create(dbeta)
   !
   !$acc parallel loop collapse(2) present(vkb)
   DO ih = 1, nh_nt
      DO ig = 1, npw
         dbeta(ig,ih) = vkb(ig,ijkb0+ih)
      ENDDO
   ENDDO
   !
#if defined(__CUDA)
   !$acc host_data use_device(wfcU,dbeta,wfatbeta,betapsi0)
   CALL calbec_gpu( npw, wfcU, dbeta, wfatbeta ) 
   CALL using_evc_d(0)
   CALL calbec_gpu( npw, dbeta, evc_d, betapsi0 )
   !$acc end host_data
#else
   CALL calbec( npw, wfcU, dbeta, wfatbeta ) 
   CALL using_evc(0)
   CALL calbec( npw, dbeta, evc, betapsi0 )
#endif
   !
   !$acc parallel loop collapse(2)
   DO ih = 1, nh(nt)
      DO ig = 1, npw
         gvec = g(ipol,igk_k(ig,ik)) * tpiba
         dbeta(ig,ih) = (0.d0,-1.d0) * dbeta(ig,ih) * gvec
      ENDDO
   ENDDO
   !
! !omp end parallel do
#if defined(__CUDA)
   CALL using_evc_d(0)
   !$acc host_data use_device(wfcU,dbeta,wfatdbeta,dbetapsi)
   CALL calbec_gpu( npw, dbeta, evc_d, dbetapsi ) 
   CALL calbec_gpu( npw, wfcU, dbeta, wfatdbeta ) 
   !$acc end host_data
#else
   CALL using_evc(0)
   CALL calbec( npw, dbeta, evc, dbetapsi ) 
   CALL calbec( npw, wfcU, dbeta, wfatdbeta )
#endif
   !
   !$acc end data
   DEALLOCATE( dbeta )
   ALLOCATE( betapsi(nh(nt),nb_s:nb_e) )
   !$acc data create( betapsi )
   !
   ! ... calculate \sum_j qq(i,j)*dbetapsi(j)
   ! ... betapsi is used here as work space 
   !
   ! ... here starts band parallelization
! !omp parallel do default(shared) private(ih,ibnd,jh)
   !$acc parallel loop collapse(2) present(qq_at)
   DO ih = 1, nh_nt
      DO ibnd = nb_s, nb_e
         bpsi_ii = (0.0_dp,0.0_dp)
         DO jh = 1, nh_nt
            bpsi_ii = bpsi_ii + qq_at(ih,jh,alpha) * dbetapsi(jh,ibnd)
         ENDDO
         betapsi(ih,ibnd) = bpsi_ii
      ENDDO
   ENDDO
! !omp end parallel do
   !
   !$acc kernels
   dbetapsi(:,nb_s:nb_e) = betapsi(:,nb_s:nb_e)
   !$acc end kernels
   !
   ! ... calculate \sum_j qq(i,j)*betapsi(j)
   !
! !omp parallel do default(shared) private(ih,ibnd,jh)
   !$acc parallel loop collapse(2) present(qq_at)
   DO ih = 1, nh_nt
      DO ibnd = nb_s, nb_e
         bpsi_ii = (0.0_dp,0.0_dp)
         DO jh = 1, nh_nt
            bpsi_ii = bpsi_ii + qq_at(ih,jh,alpha) * betapsi0(jh,ibnd)
         ENDDO
         betapsi(ih,ibnd) = bpsi_ii
      ENDDO
   ENDDO
! !omp end parallel do
   !
   ! ... dproj(iwf,ibnd) = \sum_ih wfatdbeta(iwf,ih)*betapsi(ih,ibnd) +
   ! ...                           wfatbeta(iwf,ih)*dbetapsi(ih,ibnd) 
   !
   IF ( mykey==0 .AND. nh(nt)>0 ) THEN
      !$acc host_data use_device(wfatdbeta,wfatbeta,betapsi,dbetapsi,dproj)
      CALL MYDGEMM( 'N', 'N', nwfcU, nb_e-nb_s+1, nh(nt), 1.0_dp,      &
                    wfatdbeta, nwfcU, betapsi(1,nb_s), nh(nt), 1.0_dp, &
                    dproj(1,nb_s), nwfcU )
      CALL MYDGEMM( 'N', 'N', nwfcU, nb_e-nb_s+1, nh(nt), 1.0_dp,      &
                    wfatbeta, nwfcU, dbetapsi(1,nb_s), nh(nt), 1.0_dp, &
                    dproj(1,nb_s), nwfcU )
      !$acc end host_data
   ENDIF
   !
   !$acc end data
   DEALLOCATE( betapsi )
   !
   ! ... end band parallelization - only dproj(1,nb_s:nb_e) are calculated
   !
   !$acc end data
   DEALLOCATE( betapsi0  )
   DEALLOCATE( wfatbeta  ) 
   DEALLOCATE( wfatdbeta )
   DEALLOCATE( dbetapsi  )
   !
   !$acc end data
   !
   CALL stop_clock_gpu( 'dprojdtau' )
   !
   RETURN
   !
END SUBROUTINE dprojdtau_gamma
