=head1 NAME

Photonic::Retarded::OneH

=head1 VERSION

version 0.006

=head1 SYNOPSIS

    use Photonic::Retarded::OneH;
    my $nr=Photonic::Retarded::OneH->new(geometry=>$geometry);
    $nr->iterate;
    say $nr->iteration;
    say $nr->current_a;
    say $nr->next_b2;
    my $state=$nr->nextState;

=head1 DESCRIPTION

Implements calculation of Haydock coefficients and Haydock states for
the calculation of the retarded dielectric function of arbitrary
periodic two component systems in arbitrary number of dimentions. One
Haydock coefficient at a time.

=head1 METHODS

=over 4

=item * new(metric=>$m, polarization=>$e, [, small=>$s])

Create a new Ph::R::OneH object with PDL::Retarded::Metric $m, with a
field along the complex direction $e and with smallness parameter  $s.

=back

=head1 ACCESORS (read only)

=over 4

=item * metric Photonic::Retarded::Metric 

A Photonic::Retarded::Metric object defining the geometry of the
system, the charateristic function, the wavenumber, wavevector and
host dielectric function. Required in the initializer.

=item * polarization PDL::Complex

A non null vector defining the complex direction of the macroscopic
field. 

=item * small 

A small number used as tolerance to end the iteration. Small negative
b^2 coefficients are taken to be zero.

=item * B ndims dims

Accesors handled by metric (see Photonic::Retarded::Metric, inherited
=from Photonic::Geometry)

=item * previousState currentState nextState 

The n-1-th, n-th and n+1-th Haydock states; a complex vector for each
reciprocal wavevector

=item * current_a

The n-th Haydock coefficient a

=item * current_b2 next_b2 current_b next_b

The n-th and n+1-th b^2 and b Haydock coefficients

=item * next_c

The n+1-th c Haydock coefficient

=item * current_g next_g 

The n-th and n+1-th g Haydock coefficient

=item * iteration

Number of completed iterations

=back

=head1 METHODS

=over 4

=item * iterate

Performs a single Haydock iteration and updates current_a, next_state,
next_b2, next_b, shifting the current values where necessary. Returns
0 when unable to continue iterating. 
 
=back

=cut

package Photonic::Retarded::OneH;
$Photonic::Retarded::OneH::VERSION = '0.006';
use namespace::autoclean;
use PDL::Lite;
use PDL::NiceSlice;
use PDL::FFTW3;
use PDL::Complex;
use List::Util;
use Carp;
use Moose;
#use Photonic::Types;

has 'metric'=>(is=>'ro', isa => 'Photonic::Retarded::Metric',
    handles=>[qw(B ndims dims)],required=>1
);

has 'polarization' =>(is=>'ro', required=>1, isa=>'PDL::Complex');

has 'small' => (is=>'ro', required=>1, default=>1e-7);

has 'previousState' =>(is=>'ro', isa=>'PDL::Complex',
    writer=>'_previousState', lazy=>1, init_arg=>undef, 
    default=>sub {0+i*0});

has 'currentState' => (is=>'ro', isa=>'PDL::Complex',
      writer=>'_currentState', 
      lazy=>1, init_arg=>undef,  default=>sub {0+i*0});

has 'nextState' =>(is=>'ro', isa=>'PDL::Complex|Undef', 
    writer=>'_nextState', lazy=>1, init_arg=>undef);

has 'current_a' => (is=>'ro', writer=>'_current_a',
    init_arg=>undef);

has 'current_b2' => (is=>'ro', writer=>'_current_b2',
    init_arg=>undef);

has 'next_b2' => (is=>'ro', writer=>'_next_b2', init_arg=>undef, default=>0);

has 'current_b' => (is=>'ro', writer=>'_current_b', init_arg=>undef);

has 'next_b' => (is=>'ro', writer=>'_next_b', init_arg=>undef,
                 default=>\&_firstb); 

has 'next_c' => (is=>'ro', writer=>'_next_c', init_arg=>undef, default=>0);

has 'current_g' => (is=>'ro', writer=>'_current_g', init_arg=>undef);

has 'next_g' => (is=>'ro', writer=>'_next_g', init_arg=>undef,
     default=>0, default => \&_firstg);
has 'iteration' =>(is=>'ro', writer=>'_iteration', init_arg=>undef,
                   default=>0);

sub iterate { #single Haydock iteration in N=1,2,3 dimensions
    my $self=shift;
    #Note: calculate Current a, next b2, next b, next state
    #Done if there is no next state
    return 0 unless defined $self->nextState;
    $self->_iterate_indeed; 
}
sub _iterate_indeed {
    my $self=shift;
    #Shift and fetch results of previous calculations
    $self->_previousState(my $psi_nm1=$self->currentState);
    $self->_currentState(my $psi_n #state in reciprocal space 
			 =$self->nextState);
    $self->_current_b2(my $b2_n=$self->next_b2);
    $self->_current_b(my $b_n=$self->next_b);
    $self->_previous_g(my $g_nm1=$self->current_g);
    $self->_current_g(my $g_n=$self->next_g);
    #Use eqs. 4.29-4.33 of Samuel's thesis.
    #state is RorI xy.. nx ny..
    my $gGG=$self->metric->value;
    #$gGG is xyz xyz nx ny nz, $psiG is RorI xyz nx ny nz
    my $gpsi=($gGG*$psi_n(:,:,*))->sumover; #seems real*complex works.
    # gpsi is RorI xyz nx ny nz. Get cartesian out of the way and
    # transform to real space. Note FFFTW3 wants real PDL's[2,...] 
    my $gpsi_nr=ifftn($gpsi->real->mv(1,-1), $self->ndims);
    #$gpsi_nr is RorI nx ny nz  xyz, B is nx ny nz
    # Multiply by characteristic function
    my $psi_nM1r=Cscale($gpsir, $self->B);
    #psi_nM1r is RorI nx ny nz  xyz
    #the result is RorI, nx, ny,... cartesian
    #Transform to reciprocal space, move cartesian back and make complex, 
    my $psi_nM1=fftn($nextPsir, $self->ndims)->mv(-1,1)->complex;
    my $gPsi_nM1=($gGG*gPsi_nM1(:,:,*))->sumover;
    # Eq. 4.41
    #$gpsiG and BgpsiG are RorI xyz nx ny nz
    my $an=$gn*($gpsi->Cconj*$psi_nM1)->re->sum;
    # Eq 4.43
    my $psi2_nM1=($psi_nM1->Cconj*$gPsi_nM1)->re->sum;
    # Eq. 4.30
    my $g_nM1=1;
    my $b2_nM1=$psi_nM12-$gn*$an**2-$g_nm1*$b2_n;
    $g_nM1=-1, $b2_nM1=-$b2_nM1 if $b2_nM1 < 0;
    carp "\$next_b2=$next_b2 is too negative!" if $next_b2 < -$self->small;
    my $b_nM1=sqrt($b2_nM1);
    # Eq. 4.31
    my $c_nM1=$g_nM1*$g_n*$b_nM1;
    # Eq. 4.33
    my $next_state=undef;
    $next_state=($psi_nM1-$an*$psi_n-$c_n*$psi_nm1)/$b_nM1 
	unless $b2_nM1 < $self->small;
    #save values
    $self->_nextState($next_state);
    $self->_current_a($a_n);
    $self->_next_b2($b2_nM1);
    $self->_next_b($b_nM1);
    $self->_next_g($g_nM1);
    $self->_next_c($c_nM1);
    $self->_iteration($self->iteration+1); #increment counter
    return 1;
}

sub BUILD {
    my $self=$shift;
    $d=$self->ndims;

    my $v=PDL->zeroes(@{$self->dims}); #build a nx ny nz pdl
    my $arg="(0)" . ",(0)" x ($d-1); #(0),(0),... ndims times
    $v->slice($arg).=1; #delta_{G0}
    my $e=$self->polarization; #RorI xyz
    croak "Polarization has wrong dimensions. " .
	  " Should be $d-dimensional complex vector."
	unless $e->isa('PDL::Complex') && $e->ndims==2 &&
	[$e->dims]->[0]==2 && [$e->dims]->[1]==$d; 
    my $modulus=$e->Cabs2->sumover;
    croak "Polarization should be non null" unless
	$modulus > 0;
    $e=$e/sqrt($modulus);
    my $phi=$e*$v(*); #initial state ordinarily normalized
    my $gphi=$self->metric->value*$phi(:,:,*)->sumover;
    my $g=1;
    my $b2=$psi->Cconj*$gphi->re->sum;
    $g=-1, $b2=-$b2 if $b2<0;
    $b=sqrt(b2);
    $phi=$phi/$b; #initial state;
    $self->_nextState($phi);
    #skip $self->current_a;
    $self->_next_b2($b2);
    $self->_next_b($b);
    # skip $self->next_c; no c0
    $self->_next_g($g);
}
    


#sub _firstState { #\delta_{G0}
#    my $self=shift;
#    my $v=PDL->zeroes(2,@{$self->dims})->complex; #RorI, nx, ny...
#    my $arg="(0)" . ",(0)" x $self->B->ndims; #(0),(0),... ndims+1 times
#    $v->slice($arg).=1; #delta_{G0}
#    return $v;
#}


__PACKAGE__->meta->make_immutable;
    
1;