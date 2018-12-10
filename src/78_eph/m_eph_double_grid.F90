!{\src2tex{textfont=tt}}
!!****m* ABINIT/m_eph_double_grid
!! NAME
!!  m_eph_double_grid
!!
!! FUNCTION
!!  Structure and functions to create a double grid mapping
!!
!! COPYRIGHT
!!  Copyright (C) 2008-2018 ABINIT group (HM)
!!  This file is distributed under the terms of the
!!  GNU General Public License, see ~abinit/COPYING
!!  or http://www.gnu.org/copyleft/gpl.txt .
!!
!! PARENTS
!!
!! SOURCE

#if defined HAVE_CONFIG_H
#include "config.h"
#endif

#include "abi_common.h"

module m_eph_double_grid

 use defs_basis
 use defs_abitypes
 use m_errors
 use m_ebands

 use defs_datatypes,   only : ebands_t
 use m_crystal,        only : crystal_t
 use m_fstrings,       only : itoa, sjoin

 implicit none

 private
!!***

 public :: eph_double_grid_new   ! Initialize the double grid structure
 public :: eph_double_grid_free  ! Free the double grid structure
 public :: eph_double_grid_get_index ! Get the index of the the kpoint in the double grid
 public :: eph_double_grid_bz2ibz ! Map BZ to IBZ using the double grid structure
 public :: eph_double_grid_get_mapping ! Get a mapping of k, k+q and q to the BZ and IBZ of the double grid

!----------------------------------------------------------------------

!!****t* m_eph_double_grid/eph_double_grid_t
!! NAME
!! eph_double_grid_t
!!
!! FUNCTION
!! Double grid datatype for electron-phonon
!!
!! SOURCE

 type,public :: eph_double_grid_t

   type(ebands_t) :: ebands_dense
   ! ebands structure with the eigenvalues on the dense grid

   real(dp),allocatable :: kpts_coarse(:,:)
   real(dp),allocatable :: kpts_dense(:,:)
   real(dp),allocatable :: kpts_dense_ibz(:,:)
   integer :: coarse_nbz, dense_nbz, dense_nibz

   real(dp),allocatable :: weights_dense(:)
   !weights in the dense grid

   integer,allocatable  :: bz2ibz_coarse(:)
   ! map full Brillouin zone to ibz (in the coarse grid)

   integer,allocatable  :: bz2ibz_dense(:)
   ! map full Brillouin zone to ibz (in the dense grid)

   integer :: nkpt_coarse(3), nkpt_dense(3)
   ! size of the coarse and dense meshes

   integer :: interp_kmult(3)
   ! multiplicity of the meshes

   integer :: ndiv
   ! interp_kmult(1)*interp_kmult(2)*interp_kmult(3)

   ! the integer indexes for the coarse grid are calculated for kk(3) with:
   ! [mod(nint((kpt(1)+1)*self%nkpt_coarse(1)),self%nkpt_coarse(1))+1,
   !  mod(nint((kpt(2)+1)*self%nkpt_coarse(2)),self%nkpt_coarse(2))+1,
   !  mod(nint((kpt(3)+1)*self%nkpt_coarse(3)),self%nkpt_coarse(3))+1]

   integer,allocatable :: indexes_to_coarse(:,:,:)
   ! given integer indexes get the array index of the kpoint (coarse)
   integer,allocatable :: coarse_to_indexes(:,:)
   ! given the array index get the integer indexes of the kpoints (coarse)

   integer,allocatable :: indexes_to_dense(:,:,:)
   ! given integer indexes get the array index of the kpoint (dense)
   integer,allocatable :: dense_to_indexes(:,:)
   ! given the array index get the integer indexes of the kpoint (dense)

   integer,allocatable :: coarse_to_dense(:,:)
   ! map coarse to dense mesh (nbz_coarse,mult(interp_kmult))

   integer,allocatable :: bz2lgkibz(:)
   ! map full brillouin zone of dense grid to a little group of k

   integer,allocatable :: mapping(:,:)
   ! map k, k+q and q in the IBZ and FBZ of the double grid structure

 end type eph_double_grid_t
!!***

contains  !=====================================================
!!***

!----------------------------------------------------------------------

!!****f* m_sigmaph/eph_double_grid_new
!! NAME
!!
!! FUNCTION
!!   Prepare Double grid integration
!!
!!   double grid:
!!   ----------------- interp_kmult 2
!!   |. .|.|.|.|. . .| side 1
!!   |. x|.|x|.|. x .| size 3 (2*side+1)
!!   |. .|.|.|.|. . .|
!!   -----------------
!!
!!   triple grid:
!!   ------------------- interp_kmult 3
!!   |. . .|. . .|. . .| side 1
!!   |. x .|. x .|. x .| size 3 (2*side+1)
!!   |. . .|. . .|. . .|
!!   -------------------
!!
!!   quadruple grid:
!!   --------------------------- interp_kmult 4
!!   |. . . .|.|. . .|.|. . . .| side 2
!!   |. . . .|.|. . .|.|. . . .| size 5  (2*side+1)
!!   |. . x .|.|. x .|.|. x . .|
!!   |. . . .|.|. . .|.|. . . .|
!!   |. . . .|.|. . .|.|. . . .|
!!   ---------------------------
!!
!!   . = double grid
!!   x = coarse grid
!!
!!   The fine grid is used to evaluate the weights on the coarse grid
!!   The points of the fine grid are associated to the points of the
!!   coarse grid according to proximity
!!   The integration weights are returned on the coarse grid.
!!
!!   Steps of the implementation
!!   1. Get the fine k grid from file or interpolation (ebands_dense)
!!   2. Find the matching between the k_coarse and k_dense using the double_grid object
!!   3. Calculate the phonon frequencies on the dense mesh and store them on a array
!!   4. Create an array to bring the points in the full brillouin zone to the irreducible brillouin zone
!!   5. Create a scatter array between the points in the fine grid
!!
!! INPUTS
!!
!! PARENTS
!!      m_sigmaph
!!
!! CHILDREN
!!
!! SOURCE

type (eph_double_grid_t) function eph_double_grid_new(cryst, ebands_dense, kptrlatt_coarse, kptrlatt_dense) result(eph_dg)

 implicit none

!Arguments-------------------------------
 type(crystal_t), intent(in) :: cryst
 type(ebands_t), intent(in) :: ebands_dense
 integer, intent(in) :: kptrlatt_coarse(3,3), kptrlatt_dense(3,3)

!Local variables ------------------------
 integer,parameter :: sppoldbl1=1,timrev1=1
 integer :: i_dense,i_coarse,this_dense,i_subdense,i1,i2,i3,ii,jj,kk
 integer :: nkpt_coarse(3), nkpt_dense(3), interp_kmult(3), interp_side(3)

 nkpt_coarse(1) = kptrlatt_coarse(1,1)
 nkpt_coarse(2) = kptrlatt_coarse(2,2)
 nkpt_coarse(3) = kptrlatt_coarse(3,3)
 nkpt_dense(1)  = kptrlatt_dense(1,1)
 nkpt_dense(2)  = kptrlatt_dense(2,2)
 nkpt_dense(3)  = kptrlatt_dense(3,3)

 eph_dg%dense_nbz = nkpt_dense(1)*nkpt_dense(2)*nkpt_dense(3)
 eph_dg%coarse_nbz = nkpt_coarse(1)*nkpt_coarse(2)*nkpt_coarse(3)
 interp_kmult = nkpt_dense/nkpt_coarse
 eph_dg%interp_kmult = interp_kmult
 eph_dg%nkpt_coarse = nkpt_coarse
 eph_dg%nkpt_dense = nkpt_dense
 eph_dg%ebands_dense = ebands_dense

 ! A microzone is the set of points in the fine grid belonging to a certain coarse point
 ! we have to consider a side of a certain size around the coarse point
 ! to make sure the microzone is centered around its point.
 ! The fine points shared by multiple microzones should have weights
 ! according to in how many microzones they appear
 !
 ! this is integer division
 interp_side = interp_kmult/2

 eph_dg%ndiv = (2*interp_side(1)+1)*&
               (2*interp_side(2)+1)*&
               (2*interp_side(3)+1)


 write(std_out,*) 'coarse:      ', nkpt_coarse
 write(std_out,*) 'dense:       ', nkpt_dense
 write(std_out,*) 'interp_kmult:', interp_kmult
 write(std_out,*) 'ndiv:        ', eph_dg%ndiv
 ABI_CHECK(all(nkpt_dense(:) >= nkpt_coarse(:)), 'dense mesh is smaller than coarse mesh.')

 ABI_MALLOC(eph_dg%kpts_coarse,(3,eph_dg%coarse_nbz))
 ABI_MALLOC(eph_dg%kpts_dense,(3,eph_dg%dense_nbz))
 ABI_MALLOC(eph_dg%coarse_to_dense,(eph_dg%coarse_nbz,eph_dg%ndiv))

 ABI_MALLOC(eph_dg%dense_to_indexes,(3,eph_dg%dense_nbz))
 ABI_MALLOC(eph_dg%indexes_to_dense,(nkpt_dense(1),nkpt_dense(2),nkpt_dense(3)))

 ABI_MALLOC(eph_dg%coarse_to_indexes,(3,eph_dg%dense_nbz))
 ABI_MALLOC(eph_dg%indexes_to_coarse,(nkpt_coarse(1),nkpt_coarse(2),nkpt_coarse(3)))

 ABI_MALLOC(eph_dg%bz2lgkibz,(eph_dg%dense_nbz))
 ABI_MALLOC(eph_dg%mapping,(6,eph_dg%ndiv))
 ABI_MALLOC(eph_dg%weights_dense,(eph_dg%dense_nbz))

 write(std_out,*) 'create dense to coarse mapping'
 ! generate mapping of points in dense bz to the dense bz
 ! coarse loop
 i_dense = 0
 i_coarse = 0
 do kk=1,nkpt_coarse(3)
   do jj=1,nkpt_coarse(2)
     do ii=1,nkpt_coarse(1)
       i_coarse = i_coarse + 1
       !calculate reduced coordinates of point in coarse mesh
       eph_dg%kpts_coarse(:,i_coarse) = [dble(ii-1)/nkpt_coarse(1),&
                                         dble(jj-1)/nkpt_coarse(2),&
                                         dble(kk-1)/nkpt_coarse(3)]
       !create the fine mesh
       do i3=1,interp_kmult(3)
         do i2=1,interp_kmult(2)
           do i1=1,interp_kmult(1)
             i_dense = i_dense + 1
             !calculate reduced coordinates of point in dense mesh
             eph_dg%kpts_dense(:,i_dense) =  &
                  [dble((ii-1)*interp_kmult(1)+i1-1)/(nkpt_coarse(1)*interp_kmult(1)),&
                   dble((jj-1)*interp_kmult(2)+i2-1)/(nkpt_coarse(2)*interp_kmult(2)),&
                   dble((kk-1)*interp_kmult(3)+i3-1)/(nkpt_coarse(3)*interp_kmult(3))]
             !integer indexes mapping
             eph_dg%indexes_to_dense((ii-1)*interp_kmult(1)+i1,&
                                     (jj-1)*interp_kmult(2)+i2,&
                                     (kk-1)*interp_kmult(3)+i3) = i_dense
             eph_dg%dense_to_indexes(:,i_dense) = [(ii-1)*interp_kmult(1)+i1,&
                                                   (jj-1)*interp_kmult(2)+i2,&
                                                   (kk-1)*interp_kmult(3)+i3]
           enddo
         enddo
       enddo
       eph_dg%indexes_to_coarse(ii,jj,kk) = i_coarse
       eph_dg%coarse_to_indexes(:,i_coarse) = [ii,jj,kk]
     enddo
   enddo
 enddo

 ! here we need to iterate again because we can have points of the dense grid
 ! belonging to multiple coarse points
 i_coarse = 0
 do kk=1,nkpt_coarse(3)
   do jj=1,nkpt_coarse(2)
     do ii=1,nkpt_coarse(1)
       i_coarse = i_coarse + 1

       !create a mapping from coarse to dense
       i_subdense = 0
       do i3=-interp_side(3),interp_side(3)
         do i2=-interp_side(2),interp_side(2)
           do i1=-interp_side(1),interp_side(1)
             i_subdense = i_subdense + 1
             !integer indexes mapping
             this_dense = eph_dg%indexes_to_dense(&
                    mod((ii-1)*interp_kmult(1)+i1+nkpt_dense(1),nkpt_dense(1))+1,&
                    mod((jj-1)*interp_kmult(2)+i2+nkpt_dense(2),nkpt_dense(2))+1,&
                    mod((kk-1)*interp_kmult(3)+i3+nkpt_dense(3),nkpt_dense(3))+1)

             !array indexes mapping
             eph_dg%coarse_to_dense(i_coarse,i_subdense) = this_dense
           enddo
         enddo
       enddo
     enddo
   enddo
 enddo

 ABI_CHECK(i_dense == eph_dg%dense_nbz, 'dense mesh mapping is incomplete')

 !calculate the weights of each fine point
 !different methods to distribute the weights might lead to better convergence
 !loop over coarse points
 eph_dg%weights_dense = 0
 do ii=1,eph_dg%coarse_nbz
   !loop over points in the microzone
   do jj=1,eph_dg%ndiv
     i_dense = eph_dg%coarse_to_dense(ii,jj)
     eph_dg%weights_dense(i_dense) = eph_dg%weights_dense(i_dense) + 1
   end do
 end do
 !weights_dense is array, ndiv is scalar
 eph_dg%weights_dense = 1/eph_dg%weights_dense/(interp_kmult(1)*interp_kmult(2)*interp_kmult(3))

 !3.
 ABI_MALLOC(eph_dg%kpts_dense_ibz,(3,ebands_dense%nkpt))
 eph_dg%kpts_dense_ibz = ebands_dense%kptns
 eph_dg%dense_nibz = ebands_dense%nkpt

 !4.
 write(std_out,*) 'map bz -> ibz'
 ABI_MALLOC(eph_dg%bz2ibz_dense,(eph_dg%dense_nbz))
 call eph_double_grid_bz2ibz(eph_dg, eph_dg%kpts_dense_ibz, eph_dg%dense_nibz,&
                             cryst%symrec, cryst%nsym, eph_dg%bz2ibz_dense)

end function eph_double_grid_new
!!***

!!****f* m_sigmaph/eph_double_grid_free
!! NAME
!!
!! FUNCTION
!!
!! INPUTS
!!
!! PARENTS
!!      m_sigmaph
!!
!! CHILDREN
!!
!! SOURCE

subroutine eph_double_grid_free(self)

 implicit none

 type(eph_double_grid_t) :: self

 ABI_SFREE(self%weights_dense)
 ABI_SFREE(self%bz2ibz_dense)
 ABI_SFREE(self%kpts_coarse)
 ABI_SFREE(self%kpts_dense)
 ABI_SFREE(self%kpts_dense_ibz)
 ABI_SFREE(self%coarse_to_dense)
 ABI_SFREE(self%dense_to_indexes)
 ABI_SFREE(self%indexes_to_dense)
 ABI_SFREE(self%coarse_to_indexes)
 ABI_SFREE(self%indexes_to_coarse)
 ABI_SFREE(self%bz2lgkibz)
 ABI_SFREE(self%mapping)

end subroutine eph_double_grid_free
!!***

!------------------------------------------------------------------------

!!****f* m_sigmaph/eph_double_grid_get_index
!! NAME
!!
!! FUNCTION
!!   Get the indeex of a certain k-point in the double grid
!!
!! INPUTS
!!   kpt=kpoint to be mapped (reduced coordinates)
!!   opt=Map to the coarse (1) or dense grid (2)
!!
!! PARENTS
!!      m_sigmaph
!!
!! CHILDREN
!!
!! SOURCE

integer function eph_double_grid_get_index(self,kpt,opt) result(ikpt)

 implicit none

 type(eph_double_grid_t),intent(in) :: self
 integer,intent(in) :: opt
 real(dp) :: kpt(3)

 if (opt==1) then
   ikpt = self%indexes_to_coarse(&
             mod(nint((kpt(1)+1)*self%nkpt_coarse(1)),self%nkpt_coarse(1))+1,&
             mod(nint((kpt(2)+1)*self%nkpt_coarse(2)),self%nkpt_coarse(2))+1,&
             mod(nint((kpt(3)+1)*self%nkpt_coarse(3)),self%nkpt_coarse(3))+1)
 else if (opt==2) then
   ikpt = self%indexes_to_dense(&
             mod(nint((kpt(1)+1)*self%nkpt_dense(1)),self%nkpt_dense(1))+1,&
             mod(nint((kpt(2)+1)*self%nkpt_dense(2)),self%nkpt_dense(2))+1,&
             mod(nint((kpt(3)+1)*self%nkpt_dense(3)),self%nkpt_dense(3))+1)
 else
   MSG_ERROR(sjoin("Error in eph_double_grid_get_index opt. Possible values are 1 or 2. Got", itoa(opt)))
 endif

end function eph_double_grid_get_index
!!***

!----------------------------------------------------------------------

!!****f* m_sigmaph/eph_double_grid_bz2ibz
!! NAME
!!  eph_double_grid_bz2ibz
!!
!! FUNCTION
!!  Map the points of the Full to the irreducible Brillouin zone using the
!!  indexes grid used in the double grid
!!
!! INPUTS
!!  kpt_ibz: list of kpoints coordinated in the irreducible Brillouin zone
!!  nibz: number of points in the irreducible Brillouin zone
!!  symrec: symmetry operations of the reciprocal lattice
!!  nsym: number of symmetry operations
!!  bz2ibz: indexes mapping bz to ibz
!!
!! OUTPUT
!!
!! PARENTS
!!
!! CHILDREN
!!
!! SOURCE

subroutine eph_double_grid_bz2ibz(self,kpt_ibz,nibz,symrec,nsym,bz2ibz)

 implicit none

 type(eph_double_grid_t) :: self
 integer,intent(in) :: nibz, nsym
 integer :: isym, ii, ik_ibz, ik_bz
 real(dp),intent(in) :: kpt_ibz(3,nibz)
 integer,intent(in) :: symrec(:,:,:)
 integer,intent(out):: bz2ibz(self%dense_nbz)
 real(dp) :: kpt(3), kpt_sym(3)

 !call cwtime(cpu,wall,gflops,"start")
 bz2ibz = 0
 do ik_ibz=1,nibz
   ! get coordinates of k point
   kpt(:) = kpt_ibz(:,ik_ibz)
   ! Loop over the star of q
   do isym=1,nsym
     ! Get the symmetric of q
     do ii=1,3
       kpt_sym(ii)=kpt(1)*symrec(ii,1,isym)&
                  +kpt(2)*symrec(ii,2,isym)&
                  +kpt(3)*symrec(ii,3,isym)
     end do
     ! get the index of the ibz point in bz
     ik_bz = eph_double_grid_get_index(self,kpt_sym,2)
     bz2ibz(ik_bz) = ik_ibz
   end do
 end do
 !call cwtime(cpu,wall,gflops,"stop")
 !write(msg,'(2(a,f8.2))') "little group of k mapping cpu:",cpu,", wall:",wall
 !call wrtout(std_out, msg, do_flush=.True.)

end subroutine eph_double_grid_bz2ibz
!!***

!----------------------------------------------------------------------

!!****f* m_sigmaph/eph_double_grid_mapping
!! NAME
!!  eph_double_grid_mapping
!!
!! FUNCTION
!!  Campute mapping of k, k+q and q to the indexes in the double grid structure
!!
!! INPUTS
!!  kk, kq, qpt: reduced coordinates of k, k+q and q to be mapped
!!
!! OUTPUT
!!  mapping: array with the mapping of k, k+q and q to the BZ and IBZ of the double grid structure
!!
!! PARENTS
!!
!! CHILDREN
!!
!! SOURCE

subroutine eph_double_grid_get_mapping(self,kk,kq,qpt)

 implicit none

!Arguments --------------------------------
 type(eph_double_grid_t) :: self
 real(dp) :: kk(3), kq(3), qpt(3)
!Variables --------------------------------
 integer :: jj
 integer :: ik_bz, ikq_bz, iq_bz
 integer :: ik_ibz_fine,iq_ibz_fine,ikq_ibz_fine,ik_bz_fine,ikq_bz_fine,iq_bz_fine

 ik_bz  = eph_double_grid_get_index(self,kk,1)
 ikq_bz = eph_double_grid_get_index(self,kq,1)
 iq_bz  = eph_double_grid_get_index(self,qpt,1)

 ik_bz_fine  = self%coarse_to_dense(ik_bz,1)
 ik_ibz_fine = self%bz2ibz_dense(ik_bz_fine)

 !fine grid around kq
 do jj=1,self%ndiv

   !kq
   ikq_bz_fine = self%coarse_to_dense(ikq_bz,jj)
   ikq_ibz_fine = self%bz2ibz_dense(ikq_bz_fine)

   !qq
   iq_bz_fine = self%coarse_to_dense(iq_bz,jj)
   iq_ibz_fine = self%bz2ibz_dense(iq_bz_fine)

   self%mapping(:, jj) = &
     [ik_bz_fine,  ikq_bz_fine,  iq_bz_fine,&
      ik_ibz_fine, ikq_ibz_fine, iq_ibz_fine]
 enddo

end subroutine eph_double_grid_get_mapping
!!***

end module m_eph_double_grid
!!***
