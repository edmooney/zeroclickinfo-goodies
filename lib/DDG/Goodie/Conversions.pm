package DDG::Goodie::Conversions;
# ABSTRACT: convert between various units of measurement

use strict;
use DDG::Goodie;
with 'DDG::GoodieRole::NumberStyler';

use Math::Round qw/nearest/;
use Math::SigFigs qw/:all/;
use utf8;
use YAML::XS 'LoadFile';
use List::Util qw(any);

zci answer_type => 'conversions';
zci is_cached   => 1;

use bignum;

my @types = LoadFile(share('ratios.yml'));

my %unit_to_plural = ();
my @units = ();
my %plural_to_unit = ();
foreach my $type (@types) {
    push(@units, $type->{'unit'});
    push(@units, $type->{'plural'}) unless lc $type->{'unit'} eq lc $type->{'plural'};
    push(@units, @{$type->{'aliases'}});
    push(@units, $type->{'symbol'}) if $type->{'symbol'};
    $unit_to_plural{lc $type->{'unit'}} = $type->{'plural'};
    $plural_to_unit{lc $type->{'plural'}} = $type->{'unit'};
}

# build triggers based on available conversion units:
my @triggers = map { lc $_ } @units;

triggers any => @triggers;

# match longest possible key (some keys are sub-keys of other keys):
my $keys = join '|', map { quotemeta $_ } reverse sort { length($a) <=> length($b) } @units;
my $question_prefix = qr/(?<prefix>convert|what (?:is|are|does)|how (?:much|many|long) (?:is|are)?|(?:number of)|(?:how to convert))?/i;

# guards and matches regex
my $factor_re = join('|', ('a', 'an', number_style_regex()));

my $guard = qr/^(?<question>$question_prefix)\s?(?<left_num>$factor_re*)\s?(?<left_unit>$keys)\s(?<connecting_word>in|to|into|(?:in to)|from)?\s?(?<right_num>$factor_re*)\s?(?:of\s)?(?<right_unit>$keys)[\?]?$/i;

# for 'most' results, like 213.800 degrees fahrenheit, decimal places
# for small, but not scientific notation, significant figures
my $accuracy = 3;
my $scientific_notation_sig_figs = $accuracy + 3;     
my $nearest = '.' . ('0' x ($accuracy-1)) . '1';

# For a number represented as XeY, returns 1 + Y
sub magnitude_order {
    my $number = shift;
    my $to_check = sprintf("%e", $number);
    $to_check =~ /\d++\.?\d++e\+?(?<mag>-?\d++)/i;
    return 1 + $+{mag};
}
my $maximum_input = 10**100;

handle query => sub {
    
    # hack around issues with feet and inches for now
    $_ =~ s/"/inches/;
    $_ =~ s/'/feet/;

    if($_ =~ /(\d+)\s*(?:feet|foot)\s*(\d+)(?:\s*inch(?:es)?)?/i){
        my $feetHack = $1 + $2/12;
        $_ =~ s/(\d+)\s*(?:feet|foot)\s*(\d+)(?:\s*inch(?:es)?)?/$feetHack feet/i;
    }

    # hack support for "degrees" prefix on temperatures
    $_ =~ s/ degree[s]? (centigrade|celsius|fahrenheit|rankine)/ $1/i;
    
    # hack - convert "oz" to "fl oz" if "ml" contained in query
    s/(oz|ounces)/fl oz/i if(/(ml|cup[s]?|litre|liter|gallon|pint)/i && not /fl oz/i);

    # guard the query from spurious matches
    return unless $_ =~ /$guard/;

    my @matches = ($+{'left_unit'}, $+{'right_unit'});
    return if ("" ne $+{'left_num'} && "" ne $+{'right_num'});
    my $factor = $+{'left_num'};

    # Compare factors of both units to ensure proper order when ambiguous
    # also, check the <connecting_word> of regex for possible user intentions 
    my @factor1 = (); # conversion factors, not left_num or right_num values
    my @factor2 = ();
    
    # gets factors for comparison
    foreach my $type (@types) {
        if( lc $+{'left_unit'} eq lc $type->{'unit'} || $type->{'symbol'} && $+{'left_unit'} eq $type->{'symbol'}) {
            push(@factor1, $type->{'factor'});
        }
        
        my @aliases1 = @{$type->{'aliases'}};
        foreach my $alias1 (@aliases1) {
            if(lc $+{'left_unit'} eq lc $alias1) {
                push(@factor1, $type->{'factor'});
            }
        }
        
        if(lc $+{'right_unit'} eq lc $type->{'unit'} || $type->{'symbol'} && $+{'right_unit'} eq $type->{'symbol'}) {
            push(@factor2, $type->{'factor'});
        }
        
        my @aliases2 = @{$type->{'aliases'}};
        foreach my $alias2 (@aliases2) {
            if(lc $+{'right_unit'} eq lc $alias2) {
                push(@factor2, $type->{'factor'});
            }
        }
    }

    # if the query is in the format <unit> in <num> <unit> we need to flip
    # also if it's like "how many cm in metre"; the "1" is implicitly metre so also flip
    # But if the second unit is plural, assume we want the the implicit one on the first
    # It's always ambiguous when they are both countless and plural, so shouldn't be too bad.
    if (
        "" ne $+{'right_num'}
        || (   "" eq $+{'left_num'}
            && "" eq $+{'right_num'}
            && $+{'question'} !~ qr/convert/i
            && !looks_plural($+{'right_unit'})
            && $+{'connecting_word'} !~ qr/to/i ))
    {
        $factor = $+{'right_num'};
        @matches = ($matches[1], $matches[0]);
    }
    $factor = 1 if ($factor =~ qr/^(a[n]?)?$/i);

    my $styler = number_style_for($factor);
    return unless $styler;

    return unless $styler->for_computation($factor) < $maximum_input;

    my $result = convert({
        'factor' => $styler->for_computation($factor),
        'from_unit' => $matches[0],
        'to_unit' => $matches[1],
    });

    return unless defined $result->{'result'};

    my $formatted_result = sprintf("%.${accuracy}f", $result->{'result'});
    $formatted_result = FormatSigFigs($result->{'result'}, $accuracy) if abs($result->{'result'}) < 1;

    # if $result = 1.00000 .. 000n, where n <> 0 then $result != 1 and throws off pluralization, so:
    $result->{'result'} = nearest($nearest, $result->{'result'});

    if ($result->{'result'} == 0 || magnitude_order($result->{result}) >= 2*$accuracy + 1) {
        # rounding error
        $result = convert({
            'factor' => $styler->for_computation($factor),
            'from_unit' => $matches[0],
            'to_unit' => $matches[1],
        }) or return;

        # We only display it in exponent form if it's above a certain number.
        # We also want to display numbers from 0 to 1 in exponent form.
        if($result->{'result'} > 9_999_999 || abs($result->{'result'}) < 1) {
            $formatted_result = (sprintf "%.${scientific_notation_sig_figs}g", $result->{'result'});
        }
    }

    # handle pluralisation of units
    # however temperature is never plural and does require "degrees" to be prepended
    if ($result->{'type'} eq 'temperature') {
        $result->{'from_unit'} = ($factor == 1 ? "degree" : "degrees") . " $result->{'from_unit'}" if ($result->{'from_unit'} ne "kelvin");
        $result->{'to_unit'}   = ($result->{'result'} == 1 ? "degree" : "degrees") . " $result->{'to_unit'}" if ($result->{'to_unit'}   ne "kelvin");
    } else {
        $result->{'from_unit'} = set_unit_pluralisation($result->{'from_unit'}, $factor);
        $result->{'to_unit'}   = set_unit_pluralisation($result->{'to_unit'},   $result->{'result'});
    }

    $result->{'result'} = $formatted_result;
    $result->{'result'} =~ s/\.0{$accuracy}$//;
    $result->{'result'} = $styler->for_display($result->{'result'});

    my $computable_factor = $styler->for_computation($factor);
    if (magnitude_order($computable_factor) > 2*$accuracy + 1) {
        $factor = sprintf('%g', $computable_factor);
    };
    $factor = $styler->for_display($factor);

    return "$factor $result->{'from_unit'} = $result->{'result'} $result->{'to_unit'}",
        structured_answer => {
          data => {
              raw_input         => $styler->for_computation($factor),
              raw_answer        => $styler->for_computation($result->{'result'}),
              left_unit         => $result->{'from_unit'},
              right_unit        => $result->{'to_unit'},
              markup_input      => $styler->with_html($factor),
              styled_output     => $styler->with_html($result->{'result'}),
              physical_quantity => $result->{'type'}
          },
          templates => {
              group => 'base',
              options => {
                  content => 'DDH.conversions.content'
              }
          }
      };
};

sub looks_plural {
    my ($input) = @_;
    return defined $plural_to_unit{lc $input};
}

sub convert_temperatures {
    my ($from, $to, $in_temperature) = @_;

    my $kelvin;
    # Convert to SI (Kelvin)
    if    ($from =~ /^f(?:ahrenheit)?$/i) { $kelvin = ($in_temperature + 459.67) * 5/9; }
    elsif ($from =~ /^c(?:elsius)?$/i)    { $kelvin = $in_temperature + 273.15; }
    elsif ($from =~ /^k(?:elvin)?$/i)     { $kelvin = $in_temperature; }
    elsif ($from =~ /^r(?:ankine)?$/i)    { $kelvin = $in_temperature * 5/9; }
    elsif ($from =~ /^reaumur$/i)         { $kelvin = $in_temperature * 5/4 + 273.15 }
    else { die; }
    
    my $out_temperature;
    # Convert to Target Unit
    if    ($to   =~ /^f(?:ahrenheit)?$/i) { $out_temperature = $kelvin * 9/5 - 459.67; }
    elsif ($to   =~ /^c(?:elsius)?$/i)    { $out_temperature = $kelvin - 273.15; }
    elsif ($to   =~ /^k(?:elvin)?$/i)     { $out_temperature = $kelvin; }
    elsif ($to   =~ /^r(?:ankine)?$/i)    { $out_temperature = $kelvin * 9/5; }
    elsif ($to   =~ /^reaumur$/i)         { $out_temperature = ($kelvin - 273.15) * 4/5; }
    else { die; }

    return $out_temperature;
}
sub get_matches {
    my @input_matches = @_;
    my @output_matches = ();
    foreach my $match (@input_matches) {
        foreach my $type (@types) {
            if ($type->{'symbol'} && $match eq $type->{'symbol'}
             || lc $match eq lc $type->{'unit'}
             || lc $match eq lc $type->{'plural'}
             || grep { $_ eq lc $match } @{$type->{'aliases'}} ) {
                push(@output_matches,{
                    type => $type->{'type'},
                    factor => $type->{'factor'},
                    unit => $type->{'unit'},
                    can_be_negative => $type->{'can_be_negative'} || '0'
                });
            }
        }
    }
    return @output_matches;
}
sub convert {
    my ($conversion) = @_;

    my @matches = get_matches($conversion->{'from_unit'}, $conversion->{'to_unit'});
	return if scalar(@matches) != 2;
    return if $conversion->{'factor'} < 0 && !($matches[0]->{'can_be_negative'}); 

    # matches must be of the same type (e.g., can't convert mass to length):
    return if ($matches[0]->{'type'} ne $matches[1]->{'type'});

    my $result;
    # run the conversion:
    # temperatures don't have 1:1 conversions, so they get special treatment:
    if ($matches[0]->{'type'} eq 'temperature') {
        $result = convert_temperatures($matches[0]->{'unit'}, $matches[1]->{'unit'}, $conversion->{'factor'})
    }
    else {
        $result = $conversion->{'factor'} * ($matches[1]->{'factor'} / $matches[0]->{'factor'});
    }
    return {
        "result" => $result,
        "from_unit" => $matches[0]->{'unit'},
        "to_unit" => $matches[1]->{'unit'},
        "type"  => $matches[0]->{'type'}
    };
}

sub set_unit_pluralisation {
    my ($unit, $count) = @_;
    $unit = $unit_to_plural{lc $unit} if ($count != 1 && !looks_plural($unit));
    return $unit;
}

1;
