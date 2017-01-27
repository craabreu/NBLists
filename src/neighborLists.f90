module neighborLists

use global
use lists
use omp_lib

implicit none

integer, parameter, private :: extra = 2000

integer, parameter, private :: ndiv = 2
integer, parameter, private :: nbcells = 62
integer, parameter, private :: nb(3,nbcells) = reshape( [ &
   1, 0, 0,    2, 0, 0,   -2, 1, 0,   -1, 1, 0,    0, 1, 0,    1, 1, 0,    2, 1, 0,   -2, 2, 0,  &
  -1, 2, 0,    0, 2, 0,    1, 2, 0,    2, 2, 0,   -2,-2, 1,   -1,-2, 1,    0,-2, 1,    1,-2, 1,  &
   2,-2, 1,   -2,-1, 1,   -1,-1, 1,    0,-1, 1,    1,-1, 1,    2,-1, 1,   -2, 0, 1,   -1, 0, 1,  &
   0, 0, 1,    1, 0, 1,    2, 0, 1,   -2, 1, 1,   -1, 1, 1,    0, 1, 1,    1, 1, 1,    2, 1, 1,  &
  -2, 2, 1,   -1, 2, 1,    0, 2, 1,    1, 2, 1,    2, 2, 1,   -2,-2, 2,   -1,-2, 2,    0,-2, 2,  &
   1,-2, 2,    2,-2, 2,   -2,-1, 2,   -1,-1, 2,    0,-1, 2,    1,-1, 2,    2,-1, 2,   -2, 0, 2,  &
  -1, 0, 2,    0, 0, 2,    1, 0, 2,    2, 0, 2,   -2, 1, 2,   -1, 1, 2,    0, 1, 2,    1, 1, 2,  &
   2, 1, 2,   -2, 2, 2,   -1, 2, 2,    0, 2, 2,    1, 2, 2,    2, 2, 2 ], shape(nb) )

type, private :: tCell
  integer :: neighbor(nbcells)
end type tCell

type, private :: tData

  integer :: natoms                       ! Number of atoms in the system
  integer :: mcells = 0                   ! Number of cells at each dimension
  integer :: ncells = 0                   ! Total number of cells
  integer :: maxcells = 0                 ! Maximum number of cells
  integer :: maxatoms = 0                 ! Maximum number of atoms in a cell
  integer :: maxpairs = 0                 ! Maximum number of pairs formed by all atoms of a cell
  integer :: nthreads                     ! Number of parallel openmp threads
  integer :: threadAtoms                  ! Number of atoms per parallel thread

  real(rb) :: Rc                          ! Cut-off distance
  real(rb) :: RcSq                        ! Cut-off distance squared
  real(rb) :: xRc                         ! Extended cutoff distance (including skin)
  real(rb) :: xRcSq                       ! Extended cutoff distance squared
  real(rb) :: skinSq                      ! Square of the neighbor list skin width

  type(tList) :: cellAtom                 ! List of atoms belonging to each cell
  type(tList) :: threadCell               ! List of cells to be dealt with in each parallel thread

  integer, allocatable :: atomCell(:)     ! Array containing the current cell of each atom
  integer, allocatable :: body(:)         ! Array containing the body index of each atom

  real(rb), allocatable :: R0(:,:)        ! Position of each atom at latest neighbor list building

  type(tCell), allocatable :: cell(:)      ! Array containing all neighbor cells of each cell
  type(tList), allocatable :: neighbor(:)  ! Pointer to neighbor lists

end type tData

type, bind(C) :: nbList
  type(c_ptr) :: first
  type(c_ptr) :: last
  type(c_ptr) :: item
  integer(ib) :: builds                    ! Number of neighbor list builds
  real(rb)    :: time                      ! Time taken in neighbor list handling
  type(c_ptr) :: Data                      ! Pointer to system data
end type nbList

contains

!===================================================================================================
!                                L I B R A R Y   P R O C E D U R E S
!===================================================================================================

  function neighbor_list( threads, rc, skin, N, body ) bind(C,name="neighbor_list")
    integer(ib), value :: threads, N
    real(rb),    value :: rc, skin
    type(c_ptr), value :: body
    type(nbList)       :: neighbor_list

    integer :: i

    type(tData), pointer :: me
    integer,     pointer :: pbody(:)

    ! Allocate data structure:
    allocate( me )

    ! Set up fixed entities:
    me%nthreads = threads
    me%Rc = rc
    me%RcSq = rc*rc
    me%xRc = rc + skin
    me%xRcSq = me%xRc**2
    me%skinSq = skin*skin
    me%natoms = N
    me%threadAtoms = (N + threads - 1)/threads

    ! Set up body:
    if (c_associated(body)) then
      call c_f_pointer( body, pbody, [N] )
      allocate( me%body(N), source = pbody )
    else
      allocate( me%body(N), source = [(i,i=1,N)] )
    end if

    ! Initialize counters and other mutable entities:
    allocate( me%R0(3,N), source = zero )
    allocate( me%cell(0) )
    allocate( me%atomCell(N) )

    ! Allocate memory for list of atoms per cell:
    call me % cellAtom % allocate( N, 0 )

    ! Allocate memory for neighbor lists:
    allocate( me%neighbor(threads) )
    call me % neighbor % allocate( extra, N )

    ! Set up mutable entities:
    neighbor_list % data = c_loc(me)

  end function neighbor_list

!===================================================================================================

  real(rb) function maximum_approach_sq( N, delta )
    integer,  intent(in) :: N
    real(rb), intent(in) :: delta(3,N)

    integer  :: i
    real(rb) :: maximum, next, deltaSq

    maximum = sum(delta(:,1)**2)
    next = maximum
    do i = 2, N
      deltaSq = sum(delta(:,i)**2)
      if (deltaSq > maximum) then
        next = maximum
        maximum = deltaSq
      end if
    end do
    maximum_approach_sq = maximum + 2*sqrt(maximum*next) + next

  end function maximum_approach_sq

!===================================================================================================

  subroutine distribute_atoms( me, M, Rs )
    type(tData), intent(inout) :: me
    integer,     intent(in)    :: M
    real(rb),    intent(in)    :: Rs(3,me%natoms)

    integer :: MM, cells_per_thread, maxNatoms, threadNatoms(me%nthreads), next(me%natoms)
    logical :: make_cells
    integer, allocatable :: natoms(:)

    MM = M*M
    make_cells = M /= me%mcells
    if (make_cells) then
      me%mcells = M
      me%ncells = M*MM
      if (me%ncells > me%maxcells) then
        deallocate( me%cell, me%cellAtom%first, me%cellAtom%last )
        allocate( me%cell(me%ncells), me%cellAtom%first(me%ncells), me%cellAtom%last(me%ncells) )
        call me % threadCell % allocate( 0, me%nthreads )
        me%maxcells = me%ncells
      end if
      cells_per_thread = (me%ncells + me%nthreads - 1)/me%nthreads
    end if

    allocate( natoms(me%ncells) )

    !$omp parallel num_threads(me%nthreads) reduction(max:maxNatoms)
    call distribute( omp_get_thread_num() + 1, maxNatoms )
    !$omp end parallel
    me%maxatoms = maxNatoms
    me%maxpairs = (maxNatoms*((2*nbcells + 1)*maxNatoms - 1))/2

    contains
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
      subroutine distribute( thread, maxNatoms )
        integer, intent(in)  :: thread
        integer, intent(out) :: maxNatoms

        integer :: i, k, icell, ix, iy, iz, first, last, atoms_per_thread
        integer :: icoord(3)
        integer, allocatable :: head(:)

        if (make_cells) then
          first = (thread - 1)*cells_per_thread + 1
          last = min( thread*cells_per_thread, me%ncells )
          do icell = first, last
            k = icell - 1
            iz = k/MM
            iy = (k - iz*MM)/M
            ix = k - (iy*M + iz*MM)
            me%cell(icell)%neighbor = 1 + pbc(ix+nb(1,:)) + pbc(iy+nb(2,:))*M + pbc(iz+nb(3,:))*MM
          end do
          me%threadCell%first(thread) = first
          me%threadCell%last(thread) = last
        else
          first = me%threadCell%first(thread)
          last = me%threadCell%last(thread)
        end if

        atoms_per_thread = (me%natoms + me%nthreads - 1)/me%nthreads
        do i = (thread - 1)*atoms_per_thread + 1, min( thread*atoms_per_thread, me%natoms )
          icoord = int(M*(Rs(:,i) - floor(Rs(:,i))),ib)
          me%atomCell(i) = 1 + icoord(1) + M*icoord(2) + MM*icoord(3)
        end do
        !$omp barrier

        allocate( head(first:last) )
        head = 0
        natoms(first:last) = 0
        do i = 1, me%natoms
          icell = me%atomCell(i)
          if ((icell >= first).and.(icell <= last)) then
            next(i) = head(icell)
            head(icell) = i
            natoms(icell) = natoms(icell) + 1
          end if
        end do
        threadNatoms(thread) = sum(natoms(first:last))
        !$omp barrier

        maxNatoms = 0
        k = sum(threadNatoms(1:thread-1))
        do icell = first, last
          me%cellAtom%first(icell) = k + 1
          i = head(icell)
          do while (i /= 0)
            k = k + 1
            me%cellAtom%item(k) = i
            i = next(i)
          end do
          me%cellAtom%last(icell) = k
          if (natoms(icell) > maxNatoms) maxNatoms = natoms(icell)
        end do
      end subroutine distribute
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
      elemental integer function pbc( x )
        integer, intent(in) :: x
        if (x < 0) then
          pbc = x + M
        else if (x >= M) then
          pbc = x - M
        else
          pbc = x
        end if
      end function pbc
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
  end subroutine distribute_atoms

!===================================================================================================

  subroutine find_pairs( me, thread, invL, Rs )
    type(tData), intent(inout) :: me
    integer,     intent(in)    :: thread
    real(rb),    intent(in)    :: invL, Rs(3,me%natoms)

    integer  :: i, j, k, m, n, icell, jcell, npairs, ibody
    integer  :: nlocal, ntotal, first, last
    real(rb) :: xRc2, Rc2, r2
    integer  :: atom(me%maxpairs)
    real(rb) :: Ri(3), Rij(3), invL2

    invL2 = invL*invL
    xRc2 = me%xRcSq*invL2
    Rc2 = me%RcSq*invL2

    npairs = 0
    associate (neighbor => me%neighbor(thread))
      do icell = me%threadCell%first(thread), me%threadCell%last(thread)

        if (neighbor%nitems < npairs + me%maxpairs) then
          call neighbor % resize( npairs + me%maxpairs + extra )
        end if

        first = me%cellAtom%first(icell)
        last = me%cellAtom%last(icell)
        nlocal = last - first + 1
        atom(1:nlocal) = me%cellAtom%item(first:last)

        ntotal = nlocal
        do m = 1, nbcells
          jcell = me%cell(icell)%neighbor(m)
          first = me%cellAtom%first(jcell)
          last = me%cellAtom%last(jcell)
          n = ntotal + 1
          ntotal = n + last - first
          atom(n:ntotal) = me%cellAtom%item(first:last)
        end do

        do k = 1, nlocal
          i = atom(k)
          ibody = me%body(i)
          neighbor%first(i) = npairs + 1
          Ri = Rs(:,i)
          do m = k + 1, ntotal
            j = atom(m)
            if (me%body(j) /= ibody) then ! Do not include pairs of atoms in the same body
              Rij = Ri - Rs(:,j)
              Rij = Rij - anint(Rij)
              r2 = sum(Rij*Rij)
              if (r2 < xRc2) then
                npairs = npairs + 1
                neighbor%item(npairs) = j
              end if
            end if
          end do
          neighbor%last(i) = npairs
        end do

      end do
      neighbor%count = npairs
    end associate

  end subroutine find_pairs

!===================================================================================================

  subroutine neighbor_handle( list, Lbox, positions ) bind(C,name="neighbor_handle")
    type(nbList), intent(inout) :: list
    real(rb),     value         :: Lbox
    type(c_ptr),  value         :: positions

    integer  :: M
    real(rb) :: invL, time
    logical  :: buildList
    real(rb), pointer     :: R(:,:)
    real(rb), allocatable :: Rs(:,:)
    type(tData),  pointer :: me

    call c_f_pointer( list%data, me )
    list%time = list%time - omp_get_wtime()

    call c_f_pointer( positions, R, [3,me%natoms])

    buildList = maximum_approach_sq( me%natoms, R - me%R0 ) > me%skinSq
    if (buildList) then
      M = floor(ndiv*Lbox/me%xRc)
      allocate( Rs(3,me%natoms) )
      invL = one/Lbox
      Rs = invL*R
      call distribute_atoms( me, max(M,2*ndiv+1), Rs )

      !$omp parallel num_threads(me%nthreads)
      block
        integer :: thread
        thread = omp_get_thread_num() + 1
        call find_pairs_and_compute( me, thread, InvL, Rs )
      end block
      !$omp end parallel

      me%R0 = R
      list%builds = list%builds + 1
    endif

    time = omp_get_wtime()
    list%time = list%time + time

  end subroutine neighbor_handle

!===================================================================================================

end module neighborLists
