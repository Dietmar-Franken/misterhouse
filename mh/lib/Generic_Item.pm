use strict;

package Generic_Item_Hash;

require Tie::Hash;
@Generic_Item_Hash::ISA = ('Tie::ExtraHash');

sub STORE { 
  my $oldValue = $_[0][0]{$_[1]};
  $_[0][0]{$_[1]} = $_[2];

  if(defined $oldValue and defined $_[2] and $oldValue ne $_[2]) {
    $_[0][1]->property_changed($_[1],$_[2], $oldValue);
  }
}


# This is the parent object for all state-based mh objects.  
# It can also be used stand alone.

package Generic_Item;

my (@reset_states, @states_from_previous_pass, @recently_changed);
use vars qw(@items_with_tied_times);

sub new {
    my ($class) = @_;
    my %myhash;
    my $self = \%myhash;
    tie %myhash, 'Generic_Item_Hash', $self;
    bless $self, $class;

                                # Use undef ... '' will return as defined
    $$self{state}         = undef;
    $$self{said}          = undef;
    $$self{state_now}     = undef;
    $$self{state_changed} = undef;
    return $self;
}

sub property_changed {
    my ($self, $property, $new_value, $old_value) = @_;
#   print "s=$self: property_changed: $property ='$new_value' (was '$old_value')\n";
}

sub set {
    my ($self, $state, $set_by, $respond) = @_;

    # Check for tied or repeated states.
    return if &main::check_for_tied_filters($self, $state, $set_by);

    # Override any set_by_timer requests
    if ($$self{timer}) {
        &Timer::unset($$self{timer});
        delete $$self{timer};
    }

    # Some devices may need to see states and substates in a case sensitive manner
    # this flg allows them to do so.
    $state = lc($state) unless $self->{states_casesensitive};

    if ($state and lc($state) eq 'toggle') {
        my $state_current = $$self{state};
                        # If states are defined, toggle will pick the next one
        if ($$self{states}) {
            my @s = @{$$self{states}};
            my $i = 0;
            while ($i < @s) {
                last if $s[$i] eq $state_current;
                $i++;
            }
            $i++;
            $i = 0 if $i > $#s;
            $state = $s[$i];
        }
        else {
            $state = ($state_current eq 'on') ? 'off' : 'on';
        }
        &main::print_log("Toggling $self->{object_name} from $state_current to $state");
    }
    $respond = $main::Respond_Target unless $respond;

                                # Handle overloaded state processing
    unless ($self->{states_nosubstate}) {
        my ($primarystate, $substate) = split(/:/, $state, 2);
        my $setcall = 'setstate_' . lc($primarystate);
        if($self->can($setcall)) {
                          # Some devices may need to wait for the set to occur
                          # (for example the Compool which doesn't actually change a state
                          # until the device has confirmed the requested action has been performed)
            return if $self->$setcall($substate, $set_by, $respond) == -1;
        }
        elsif($self->can('default_setstate')) {
            return if $self->default_setstate($primarystate, $substate, $set_by, $respond) == -1;
        }
        elsif ($self->can('default_setrawstate')) {
            return if $self->default_setrawstate($state, $set_by, $respond) == -1;
        }
    }
                                # Allow for default setstate methods
    else {
        if ($self->can('default_setstate')) {
            return if $self->default_setstate($state, undef, $set_by, $respond) == -1;
        }
        elsif ($self->can('default_setrawstate')) {
            return if $self->default_setrawstate($state, $set_by, $respond) == -1;
        }
    }

    &set_states_for_next_pass($self, $state, $set_by, $respond);

}

sub get_object_name {
    return $_[0]->{object_name};
}
sub set_by {
    $_[0]->{set_by} = $_[1];
}
sub get_set_by {
    return $_[0]->{set_by};
}
sub set_target {
    $_[0]->{target} = $_[1];
}
sub get_target {
    return $_[0]->{target};
}
sub get_changed_by {            # Grandfathered old syntax
    return $_[0]->{set_by};
}

sub get_idle_time {
    return undef unless  $_[0]->{set_time};
    return $main::Time - $_[0]->{set_time};
}

sub time_idle {
    my ($self, $idle_spec) = @_;
                                # Defaults to seconds if idletimetype is not specified
                                # Defaults to all states if currentstate is not given.
                                # Examples: '10 minutes', '2 seconds off', '24 h', '7 days', '1 hour on'
    if (my ($idle_time, $idle_type, $idle_state) = $idle_spec =~ /^(\d+)\s*(D|H|M|S)*\w*\s*(\S*)/i) {
        my $state = $self->state();
        if ($idle_state eq undef or $idle_state eq $state) {
            my $scale = 1;
            $scale = 60       if $idle_type eq 'm';
            $scale = 60*60    if $idle_type eq 'h';
            $scale = 60*60*24 if $idle_type eq 'd';
            if (($idle_time * $scale) <= $self->get_idle_time()) {
                return 1;
            }
        }
    }
    return 0;
}

                                # This is called by mh on exit to save persistant data
sub restore_string {
    my ($self) = @_;

    my $state       = $self->{state};
    $state =~ s/~/\\~/g if $state;
    my $restore_string;
    $restore_string .= $self->{object_name} . "->{state} = q~$state~;\n" if defined $state;
    $restore_string .= $self->{object_name} . "->{count} = q~$self->{count}~;\n" if $self->{count};
    $restore_string .= $self->{object_name} . "->{set_time} = q~$self->{set_time}~;\n" if $self->{set_time};
    $restore_string .= $self->{object_name} . "->{states_casesensitive} = 1;\n" if $self->{states_casesensitive};

    if ($self->{state_log} and my $state_log = join($;, @{$self->{state_log}})) {
        $state_log =~ s/\n/ /g; # Avoid new-lines on restored vars
        $state_log =~ s/~/\\~/g;
        $restore_string .= '@{' . $self->{object_name} . "->{state_log}} = split(\$;, q~$state_log~);";
    }
    
                                # Allow for dynamicaly/user defined save data
    for my $restore_var (@{$$self{restore_data}}) {
        my $restore_value = $self->{$restore_var};
        $restore_string .= $self->{object_name} . "->{$restore_var} = q~$restore_value~;\n" if defined $restore_value;
    }

    return $restore_string;
}

sub restore_data {
    return unless $main::Reload;
    my ($self, @restore_vars) = @_;
    push @{$$self{restore_data}}, @restore_vars;
}


sub hidden {
    return unless $main::Reload;
    my ($self, $flag) = @_;
                                # Set it
    if (defined $flag) {
        $self->{hidden} = $flag;
    }
    else {                      # Return it, but this currently only will work on $Reload.
        return $self->{hidden};
    }
}

sub set_casesensitive {
    return unless $main::Reload;
    my ($self) = @_;
    $self->{states_casesensitive} = 1;
}

sub state {
    my ($self, $state) = @_;

    $state = lc($state) unless defined $self->{states_casesensitive};

    if($state) {
        my $getcall = 'getstate_' . lc($state);
        return $self->$getcall() if $self->can($getcall);
    }

    return $self->default_getstate($state) if $self->can('default_getstate');

    # No need to lc() the state here, we will return what was originally set.
    return $self->{state};
} 

sub said {
                                # Set global Respond_Target var, so user code doesn't have to bother
    $main::Respond_Target = $_[0]->{target};
    return $_[0]->{said};
}

sub state_now {
    $main::Respond_Target = $_[0]->{target};
    return $_[0]->{state_now};
}
sub state_changed {
    return $_[0]->{state_changed};
}

sub state_log {
    my ($self) = @_;
    return @{$$self{state_log}} if $$self{state_log};
}

                                # Allow for turning off ~;: state processing
sub state_overload {
    my ($self, $flag) = @_;
    if (lc $flag eq 'off') {
        $self->{states_nomultistate} = 1;
        $self->{states_nosubstate}   = 1;
    }
    elsif (lc $flag eq 'on') {
        $self->{states_nomultistate} = 0;
        $self->{states_nosubstate}   = 0;
    }
}
        
sub set_icon {
    return unless $main::Reload;
    my ($self, $icon) = @_;
                                # Set it
    if (defined $icon) {
        $self->{icon} = $icon;
    }
    else {                      # Return it
        return $self->{icon};
    }
}

sub set_info {
    return unless $main::Reload;
    my ($self, $text) = @_;
                                # Set it
    if (defined $text) {
        $self->{info} = $text;
    }
    else {                      # Return it
        return $self->{info};
    }
}


sub set_with_timer {
    my ($self, $state, $time, $return_state, $additional_return_states) = @_;
    return if &main::check_for_tied_filters($self, $state);
 
                                # If blank state, then we wanted the timed return_state only
    $self->set($state) unless $state eq '';

    return unless $time;
                                # If off, timeout to on, otherwise timeout to off
    my $state_change;
    $state_change = ($state eq 'off') ? 'on' : 'off';
    $state_change = $return_state if defined $return_state;
    $state_change = $self->{state} if $return_state and lc $return_state eq 'previous';

    # Handle additoinal return states if requested (this is done so we don't need to parse for
    # ; seperators in this function, that work has already been done in MH)
    $state_change .= ';' . $additional_return_states if $additional_return_states;
 
 
                                # Reuse timer for this object if it exists
    $$self{timer} = &Timer::new() unless $$self{timer};
    my $object = $self->{object_name};
#   my $action = "set $object '$state_change'";
    my $action = "set $object '$state_change', $object";  # Set set_by to  itself??
#   my $action = "&X10_Items::set($object, '$state_change')";
#   print "db Setting x10 timer $x10_timer: self=$self time=$time action=$action\n";
#   $x10_timer->set($time, $action);
    &Timer::set($$self{timer}, $time, $action);
}

sub incr_count {
    my ($self) = @_;
    $self->{count}++;
    return;
}

sub reset_count {
    my ($self) = @_;
    $self->{count} = 0;
    return;
}

sub set_count {
    my ($self,$val) = @_;
    				# Set it
    if (defined $val) {
        $self->{count} = $val;
    }
    else {                      # Return it
        return $self->{count};
    }
}

sub get_count {
    my ($self,$val) = @_;
    				# Set it
    if (defined $val) {
        $self->{count} = $val;
    }
    else {                      # Return it
        return $self->{count};
    }
}


sub set_label {
    return unless $main::Reload;
    my ($self, $label) = @_;
                                # Set it
    if (defined $label) {
        $self->{label} = $label;
    }
    else {                      # Return it
        return $self->{label};
    }
}

sub set_authority {
    return unless $main::Reload;
    my ($self, $who) = @_;
    $self->{authority} = $who;
}
sub get_authority {
    return $_[0]->{authority};
}

sub set_type {
	my ($self, $type) = @_;
	$$self{type}=$type;
}

sub get_type {
    return $_[0]->{type};
}


sub set_fp_location {
    my ($self, @location) = @_;
    @{$$self{location}}=@location;
}


sub get_fp_location {
    my ($self) = @_;
    if (! defined @{$$self{location}} ) { return }
   return @{$$self{location}};
}

sub set_fp_nodes {
    my ($self, @nodes) = @_;
    @{$$self{nodes}}=@nodes;
}

sub get_fp_nodes {
    my ($self) = @_;
    return @{$$self{nodes}};
}

sub set_fp_icons {
    return unless $main::Reload;
    my ($self, %icons) = @_;
    %{$$self{fp_icons}}=%icons;
}

sub get_fp_icons {
    my ($self) = @_;
    if ($$self{fp_icons}) {
	return %{$$self{fp_icons}};
    } else {
	return undef;
    }
}

sub set_states {
    return unless $main::Reload;
    my ($self, @states) = @_;
    @{$$self{states}} = @states;
}
sub add_states {
    return unless $main::Reload;
    my ($self, @states) = @_;
    push @{$$self{states}}, @states;
}
sub get_states {
    my ($self) = @_;
    return @{$$self{states}};
}

sub set_states_for_next_pass {
    my ($ref, $state, $set_by, $target) = @_;
    push @states_from_previous_pass, $ref unless $ref->{state_next_pass} and @{$ref->{state_next_pass}};
    push @{$ref->{state_next_pass}}, $state;

                                # Used in get_idle_time
    $ref->{set_time} = $main::Time;

                                # If set by another object, find/use object name
    my $set_by_type = ref($set_by);
#   print "dbx1 sb=$set_by r=$set_by_type\n";
    $set_by = $set_by->{object_name} if $set_by_type and $set_by_type ne 'SCALAR';

                                # Else set to Usercode [calling code file]
    $set_by = &main::get_calling_sub() unless $set_by;
    $set_by = $main::Set_By if !$set_by and $main::Set_By;

                                # Store this for use on net pass
#   $ref->{set_by} = $set_by;
    push @{$ref->{setby_next_pass}}, $set_by;

    $target = $set_by unless defined $target;
#   $ref->{target} = $target;
    push @{$ref->{target_next_pass}}, $set_by;

                                # Set the state_log ... log non-blank states
                                # Avoid -w unintialized variable errors
    $state  = '' unless defined $state;
    $set_by = '' unless defined $set_by;
    $target = '' unless defined $target;
    unshift(@{$$ref{state_log}}, "$main::Time_Date $state set_by=$set_by target=$target")
      if $state or (ref $ref) eq 'Voice_Cmd';
    pop @{$$ref{state_log}} if $$ref{state_log} and @{$$ref{state_log}} > $main::config_parms{max_state_log_entries};

}

                                # You can use this for an undo function
sub recently_changed {
    return wantarray ? @recently_changed : $recently_changed[0];
}

                                # Reset, then set, states from previous pass
sub reset_states {
    my $ref;
    while ($ref = shift @reset_states) {
        undef $ref->{state_now};
        undef $ref->{state_changed};
        undef $ref->{said};
    }

                                # Allow for multiple sets from the same pass
                                #  - each will get run, one per subsequent pass
    my @items_with_more_states;
    while ($ref = shift @states_from_previous_pass) {
        my $state  = shift @{$ref->{state_next_pass}};
        my $set_by = shift @{$ref->{setby_next_pass}};
        my $target = shift @{$ref->{target_next_pass}};
        $ref->{state_prev}    = $ref->{state};
        $ref->{change_pass}   = $main::Loop_Count;
        $ref->{state}         = $state;
        $ref->{said}          = $state;
        $ref->{state_now}     = $state;
        $ref->{set_by}        = $set_by;
        $ref->{target}        = $target;
        push @reset_states, $ref;
        push @items_with_more_states, $ref if @{$ref->{state_next_pass}};
        if (( defined $state and !defined $ref->{state_prev}) or 
            (!defined $state and  defined $ref->{state_prev}) or 
            ( defined $state and  defined $ref->{state_prev} and $state ne $ref->{state_prev})) {
            $ref->{state_changed} = $state;
        }
                                # This allows for an 'undo' function
        unless ($ref->isa('Voice_Cmd')) {
            unshift @recently_changed, $ref;
            pop     @recently_changed if @recently_changed > 20;
        }
    }
    @states_from_previous_pass = @items_with_more_states;

                                # Set/fire tied objects/events
                                #  - do it in main, so eval works ok
    &main::check_for_tied_events(@reset_states);
}

sub tie_items {
#   return unless $main::Reload;
    my ($self, $object, $state, $desiredstate, $log_msg) = @_;
    $state         = 'all_states' unless defined $state;
    $desiredstate  = $state       unless defined $desiredstate;
    $log_msg = 1            unless $log_msg;
    return if $$self{tied_objects}{$object}{$state}{$desiredstate};
    $$self{tied_objects}{$object}{$state}{$desiredstate} = [$object, $log_msg];
}

sub tie_event {
#   return unless $main::Reload;
    my ($self, $event, $state, $log_msg) = @_;
    $state   = 'all_states' unless defined $state;
    $log_msg = 1            unless $log_msg;
    $$self{tied_events}{$event}{$state} = $log_msg;
}

sub untie_items {
    my ($self, $object, $state) = @_;
#   $state = 'all_states' unless $state;
    if ($state) {
        delete $self->{tied_objects}{$object}{$state};
    }
    elsif ($object) {
        delete $self->{tied_objects}{$object}; # Untie all states
    }
    else {
        delete $self->{tied_objects}; # Untie em all
    }
}

sub untie_event {
    my ($self, $event, $state) = @_;
#   $state = 'all_states' unless $state;
    if ($state) {
        delete $self->{tied_events}{$event}{$state};
    }
    elsif ($event) {
        delete $self->{tied_events}{$event}; # Untie all states
    }
    else {
        delete $self->{tied_events}; # Untie em all
    }        
}

sub tie_filter {
#   return unless $main::Reload;
    my ($self, $filter, $state, $log_msg) = @_;
    $state   = 'all_states' unless defined $state;
    $log_msg = 1            unless $log_msg;
    $$self{tied_filters}{$filter}{$state} = $log_msg;
}
sub untie_filter {
    my ($self, $filter, $state) = @_;
    if ($state) {
        delete $self->{tied_filters}{$filter}{$state};
    }
    elsif ($filter) {
        delete $self->{tied_filters}{$filter}; # Untie all states
    }
    else {
        delete $self->{tied_filters}; # Untie em all
    }        
}

sub tie_time {
    my ($self, $time, $state, $log_msg) = @_;
    $state   = 'on' unless defined $state;
    $log_msg = 1    unless $log_msg;
    push @items_with_tied_times, $self unless $$self{tied_times};
    $$self{tied_times}{$time}{$state} = $log_msg;
}
sub untie_time {
    my ($self, $time, $state) = @_;
    if ($state) {
        delete $self->{tied_times}{$time}{$state};
    }
    elsif ($time) {
        delete $self->{tied_times}{$time}; # Untie all states
    }
    else {
        delete $self->{tied_times}; # Untie em all
    }        
}
sub delete_old_tied_times {
    undef @items_with_tied_times;
}

sub set_web_style {
    my ( $self, $style ) = @_;

    my %valid_styles = map { $_ => 1 } qw( dropdown radio url );

    if ( !$valid_styles{ lc( $style ) } ) {
	&main::print_log( "Invalid style ($style) passed to set_web_style.  Valid choices are: " . join( ", ", sort keys %valid_styles ) );
	return;
    }

    $self->{ web_style } = lc( $style );
}

sub get_web_style {
    my $self = shift;

    return if !exists $self->{ web_style };
    return $self->{ web_style };
}

sub user_data {
	my $self = shift;
	return \%{$$self{user_data}};
}

#
# $Log$
# Revision 1.33  2004/03/23 01:58:08  winter
# *** empty log message ***
#
# Revision 1.32  2004/02/01 19:24:35  winter
#  - 2.87 release
#
# Revision 1.31  2003/12/22 00:25:05  winter
#  - 2.86 release
#
# Revision 1.30  2003/11/23 20:26:01  winter
#  - 2.84 release
#
# Revision 1.29  2003/09/02 02:48:46  winter
#  - 2.83 release
#
# Revision 1.28  2003/07/06 17:55:11  winter
#  - 2.82 release
#
# Revision 1.27  2003/04/20 21:44:07  winter
#  - 2.80 release
#
# Revision 1.26  2003/02/08 05:29:23  winter
#  - 2.78 release
#
# Revision 1.25  2003/01/12 20:39:20  winter
#  - 2.76 release
#
# Revision 1.24  2002/12/24 03:05:08  winter
# - 2.75 release
#
# Revision 1.23  2002/11/10 01:59:57  winter
# - 2.73 release
#
# Revision 1.22  2002/10/13 02:07:59  winter
#  - 2.72 release
#
# Revision 1.21  2002/09/22 01:33:23  winter
# - 2.71 release
#
# Revision 1.20  2002/08/22 04:33:20  winter
# - 2.70 release
#
# Revision 1.19  2002/05/28 13:07:51  winter
# - 2.68 release
#
# Revision 1.18  2002/03/31 18:50:38  winter
# - 2.66 release
#
# Revision 1.17  2002/03/02 02:36:51  winter
# - 2.65 release
#
# Revision 1.16  2001/12/16 21:48:41  winter
# - 2.62 release
#
# Revision 1.14  2001/05/06 21:07:26  winter
# - 2.51 release
#
# Revision 1.13  2001/04/15 16:17:21  winter
# - 2.49 release
#
# Revision 1.12  2001/02/24 23:26:40  winter
# - 2.45 release
#
# Revision 1.11  2001/02/04 20:31:31  winter
# - 2.43 release
#
# Revision 1.10  2000/10/22 16:48:29  winter
# - 2.32 release
#
# Revision 1.9  2000/10/01 23:29:40  winter
# - 2.29 release
#
# Revision 1.8  2000/09/09 21:19:11  winter
# - 2.28 release
#
# Revision 1.7  2000/08/19 01:22:36  winter
# - 2.27 release
#
# Revision 1.6  2000/06/24 22:10:54  winter
# - 2.22 release.  Changes to read_table, tk_*, tie_* functions, and hook_ code
#
# Revision 1.5  2000/02/12 06:11:37  winter
# - commit lots of changes, in preperation for mh release 2.0
#
# Revision 1.4  2000/01/27 13:39:27  winter
# - update version number
#
# Revision 1.3  1999/02/16 02:04:27  winter
# - add set method
#
# Revision 1.2  1999/01/30 19:50:51  winter
# - add state_now and reset_states loop
#
# Revision 1.1  1999/01/24 20:04:13  winter
# - created
#
#

# Debug ... will not see when using fast POSIX::_exit in bin/mh

#sub DESTROY {
#    my ($self) = @_;
#    print "Destorying object $self, name=$self->{object_name}\n";
#}
#END {
#    print "This is the end of Generic_Item\n";
#}


1;
