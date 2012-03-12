#!/usr/bin/perl -w
# Copyright © 2012 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.
#
# Build an ICS file of bands of interest at SXSW.
#
#  - First, generate a list of bands of interest by getting a list
#    of all artists with at least one song ranked 3 stars or higher
#    in iTunes.
#
#  - Then scrape sxsw.com and build ICS from it.
#
#  - Keep only events with bands of interest.
#
#  - Pull full event descriptions from sxsw.com (instead of only short
#    excerpts).
#
#  - Set location of each event to include the street address of the venue.
#
#  - Update each event to note other dates on which this band is playing
#    (so that you can look at an event on Wednesday and know that you
#    will also have an opportunity to see this band on Thursday).
#
#
# Options:
#
#   --stars 3	Set the minimum number of stars for tracks of interest.
#
#   --sched	Scrape sched.org instead of sxsw.com.  Sched lists more
#		events, but it's unclear to me which one is more reliable.
#
#   --both	What the hell, do them both (and skip duplicates).
#
# Before importing the generated .ics file into iCal, I strongly suggest:
#
#  - Check "Preferences / Advanced / Turn on time zone support".
#  - Uncheck "Preferences / General / Add a default alert".
#
# Import it into its own calendar to make it easy to nuke it and start over.
#
#
# Created:  5-Mar-2012.

require 5;
use diagnostics;
use strict;
use bytes;

use POSIX qw(mktime strftime);
use LWP::Simple;
use Date::Parse;
use DateTime;

my $progname = $0; $progname =~ s@.*/@@g;
my $version = q{ $Revision: 1.15 $ }; $version =~ s/^[^\d]+([\d.]+).*/$1/;

my $verbose = 1;
my $debug_p = 0;

my $itunes_xml = $ENV{HOME} . "/Music/iTunes/iTunes Music Library.xml";
my $base_url   = ('http://schedule.sxsw.com/2012/' .
                  '?conference=music&lsort=name&day=ALL&category=Showcase');
my $sched_url  = ('http://austin' . ((localtime)[5] + 1900) .
                  '.sched.org/all.ics');

my $zone = 'US/Central';


# Strip HTML and blank lines and stuff.
#
sub clean($) {
  my ($s) = @_;

  return '' unless defined($s);

  $s =~ s/<BR>\s*/\n/gsi;
  $s =~ s/<P>\s*/\n\n/gsi;
  $s =~ s/<[^<>]*>//gsi;

  $s =~ s/&nbsp;/ /gs;
  $s =~ s/&lt;/</gs;
  $s =~ s/&gt;/>/gs;
  $s =~ s/&amp;/&/gs;

  # Fucking Unicode. decode_utf8() does not work here and I don't know why.
  #
  $s =~ s/\342\200\220/-/gs;
  $s =~ s/\342\200\223/ -- /gs;
  $s =~ s/\342\200\224/ -- /gs;
  $s =~ s/\342\200\230/\'/gs;
  $s =~ s/\342\200\231/\'/gs;
  $s =~ s/\342\200\234/\"/gs;
  $s =~ s/\342\200\235/\"/gs;
  $s =~ s/\342\200\241/a/gs;
  $s =~ s/\342\200\242/*/gs;
  $s =~ s/\342\200\246/ /gs;
  $s =~ s/\342\200\250/*/gs;
  $s =~ s/\342\200\262/\'/gs;
  $s =~ s/\342\200\263/\"/gs;
  $s =~ s/\342\200\266/o/gs;
  $s =~ s/\303\266\171/o/gs;
  $s =~ s/\303\251/e/gs;
  $s =~ s/\303\274/u/gs;
  $s =~ s/\303\240/ -- /gs;
  $s =~ s/\312\273/\'/gs;
  $s =~ s/\312\274/\'/gs;
  $s =~ s/\037//gs;
  $s =~ s/\302 / /gs;
  $s =~ s/\302\240/ /gs;
  $s =~ s/\302\204/\"/gs;
  $s =~ s/\302\223/\"/gs;
  $s =~ s/\013/\n\n/gs;

  $s =~ s/\r\n/\n/gs;
  $s =~ s/\r/\n/gs;
  $s =~ s/\t/ /gs;
  $s =~ s/ +/ /gs;
  $s =~ s/^ +| +$//gm;
  $s =~ s/\n/\n\n/gs;
  $s =~ s/\n\n\n+/\n\n/gs;
  $s =~ s/^\s+|\s+$//gs;

  return $s;
}


# Basically a soundex hash of the string, so that punctuation and simple
# spelling mistakes don't matter.
#
sub simplify($) {
  my ($str) = @_;

  $str = lc($str);
  my $orig = $str;
  1 while ($str =~ s/\b(a|an|and|in|of|on|for|the|with|dj|los|le|les|la)\b//gi);
  $str =~ s/[^a-z\d]//g;     # lose non-alphanumeric
  $str =~ s/(.)\1+/$1/g;   # collapse consecutive letters ("xx" -> "x")
  $str = $orig if ($str eq '');
  return $str;
}


# Try hard to get the contents of the URL.
#
sub url_retry($;$) {
  my ($url, $limit) = @_;
  my $body;
  my $sec = 1;
  my $count = 0;
  while (1) {
    $body = LWP::Simple::get ($url);
    last if (length ($body) > 200);

    $count++;
    if ($limit && $count > $limit) {
      print STDERR "$progname: giving up on $url after $count tries\n";
      return "FAILED after $count tries";
    }

    print STDERR "$url: no data; retrying in $sec...\n";
    $sec = int(($sec + 2) * 1.3);
    sleep ($sec);
  }
  return $body;
}


# Get a list of highly-rated bands from the iTunes XML file.
#
sub load_bands($) {
  my ($stars) = @_;

  open (my $in, '<', $itunes_xml) || error ("$itunes_xml: $!");
  print STDERR "$progname: reading $itunes_xml\n" if ($verbose);
  local $/ = undef;  # read entire file
  my $body = <$in>;
  close $in;

  my @e = split (m@<key>Track ID</key>@, $body);
  shift @e;
  my %artists;
  foreach my $e (@e) {
    my ($r) = ($e =~ m@<key>Rating</key><integer>(\d+)@si);
    next unless (defined($r) &&
                 ($r >= $stars * 20 ||
                  ($e =~ m@<key>Has Video</key><true@si)));
    my ($a) = ($e =~ m@<key>Artist</key><string>([^<>]*)@si);
    next unless defined($a);
    $artists{simplify($a)} = $a;
  }

  my $count = keys(%artists);
  print STDERR "$progname: $count artists of ${stars}+ stars\n" if ($verbose);
  return \%artists;
}


# Quotifies the text to make it safe for iCal/vCalendar
#
sub ical_quote($;$) {
  my ($text, $nowrap) = @_;
  $text =~ s/\s+$//gs;               # lose trailing newline.
  $text =~ s/([\"\\,;])/\\$1/gs;     # quote backslash, comma, semicolon.
  $text =~ s/\r\n/\n/gs;
  $text =~ s/\r/\n/gs;

  $text =~ s/\n/\\n\n /gs;           # quote newlines, and break at newlines.

  # combine multiple blank lines into one.
  $text =~ s/(\n *\n)( *\n)+/$1/gs;

  $text =~ s/\\n/\\n\n /gs
    unless $nowrap;

  return $text;
}


# Create an ICS entry of the given event.
#
my $ics_seq = 0;
sub make_ics($$$$$$$) {
  my ($band, $url, $url2, $loc, $start, $end, $desc) = @_;

  my ($csec, $cmin, $chour, $cdotm, $cmon, $cyear) = gmtime;
  $cmon++; $cyear += 1900;
  my $dtstamp = sprintf ("%04d%02d%02dT%02d%02d%02dZ",
                         $cyear, $cmon, $cdotm, $chour, $cmin, $csec);

  $desc = "$url2\n\n$desc" if $url2;

  my $ics = join ("\n",
                  ('BEGIN:VEVENT',
                   'UID:'		. ical_quote ($url),
                   'DTSTAMP:'		. ical_quote ($dtstamp),
                   'SEQUENCE:'		. $ics_seq++,
                   'LOCATION:'		. ical_quote ($loc, 1),
                   'SUMMARY:'		. ical_quote ($band),
                   'DTSTART;'		. $start,
                   'DTEND;'		. $end,
                   'URL:'		. ical_quote ($url),
                   'DESCRIPTION:'	. ical_quote ($desc),
                   'CLASS:PUBLIC',
                   'CATEGORIES:BAND',
                   'STATUS:CONFIRMED',
                   'END:VEVENT'));
  return $ics;
}


# Returns the band's home page and description, from the given SXSW URL.
#
sub scrape_band($$) {
  my ($band, $url) = @_;

  print STDERR "$progname:   scraping \"$band\": $url\n" if ($verbose);
  my $page = url_retry ($url);

  my ($url3) = ($page =~ m@> \s* Online .*?
                           <A \s+ HREF=[\'\"]([^\'\"]+)@six);

  $page =~ s@^.*?<div \b \s+ id="main@@six;
  $page =~ s@^.*?<div \b \s+ class="block .*? > @@six;
  $page =~ s@\s* </div> .* $@@six;

  $page = '' if ($page =~ m@<h3@si);
  foreach ($url3, $page) { $_ = clean($_); }

  return ($url3, $page);
}


# Scrape each page on the SXSW web site and iterate the desired bands.
# Returns a listref of ICS events.
#
sub scrape_sxsw($$) {
  my ($artists, $dups) = @_;

  my $base = $base_url;
  $base =~ s@\?.*$@@s;

  my $cyear = (localtime)[5];

  my @events = ();
  my %venues;

  foreach $a ('1', 'a' .. 'z') {
    my $url = "$base_url&a=$a";

    print STDERR "$progname: scraping: $url\n" if ($verbose);
    my $page = url_retry ($url);

    foreach (split (m/<div\b \s+ class=\"row/six, $page)) {
      my ($url2) = (m@<a\b [^<>]*? \b href=\" (event[^<>\"]+) @six);
      my ($band) = (m@<a\b.*?> \s* ([^<>]+?) \s* </a>@six);
      my ($loc)  = (m@<div [^<>]*? \b class=\"loc[^<>]*> \s* ([^<>]+) @six);
      my ($date) = (m@<div [^<>]*? \b class=\"date[^<>]*> \s* ([^<>]+) @six);

      next unless $url2;

      foreach ($url2, $band, $loc, $date) { $_ = clean($_); }
      $url2 = $base . $url2;

      error ("no title: $_") unless $band;
      #error ("no location: $_") unless $loc;
      if (! $loc) {
        print STDERR "$progname: $band: no location!\n";
        next;
      }

      #error ("no date: $_") unless $date;
      if (! $date) {
        print STDERR "$progname: $band: no date!\n";
        next;
      }

      my $band2 = simplify ($band);
      if (! $artists->{$band2}) {
        print STDERR "$progname:   skipping \"$band\"\n" if ($verbose > 1);
        next unless $debug_p;
      }

      my ($day, $start, $end) =
       ($date =~ m/^(.*?)\s+(\d+:[^\s]+)[-\s]+(\d+:[^\s]+)\s*$/si);

#      error ("unparsable time: $date\n") unless $end;
      if (! $end) {
        print STDERR "$progname: $band: unparsable time: \"$date\"\n";
        next;
      }

      my (undef, $smm, $shh, $sdotm, $smon, $syear) = strptime ("$day, $start");
      my (undef, $emm, $ehh, $edotm, $emon, $eyear) = strptime ("$day, $end");

      $syear = $cyear unless $syear;
      $eyear = $cyear unless $eyear;
      $syear += 1900 if ($syear < 1900);
      $eyear += 1900 if ($eyear < 1900);

      # Oh, come on.  When the sxsw.com web site says "Thu Mar 15, 1:00 AM"
      # it actually means Mar 16!!  They consider the day to end at 2 AM
      # or something.  So adjust the day if the hour is "early".
      #
      $sdotm++ if ($shh < 6);
      $edotm++ if ($ehh < 6);

      my $fmt = "TZID=%s:%04d%02d%02dT%02d%02d00";
      $start = sprintf ($fmt, $zone, $syear, $smon+1, $sdotm, $shh, $smm);
      $end   = sprintf ($fmt, $zone, $eyear, $emon+1, $edotm, $ehh, $emm);


      my $st2 = $start;
      $st2 =~ s/^.*://;
      my $key = lc ("$band @ $st2");
      if ($dups->{$key}) {
        print STDERR "$progname:   skipping dup \"$key\"\n" if ($verbose > 1);
        next;
      }
      $dups->{$key} = 1;


      $venues{simplify ($loc)} = $loc;

      my $url3;
      ($url3, $page) = scrape_band ($band, $url2);

      push @events, make_ics ($band, $url2, $url3, $loc, $start, $end, $page);
    }
    last if ($debug_p > 1);
  }

  my @v = sort (values (%venues));
  return \@events;
}


# Convert a GMT time into a Central time.
#
sub fix_sched_time($) {
  my ($d) = @_;
  my ($yyyy, $mon, $dotm, $hh, $mm, $ss) = 
    ($d =~ m/^(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)Z$/si);
  if (! $yyyy) {
    print STDERR "$progname: unparsable date: $d\n";
    return ":$d";
  }

  my $d2 = DateTime->new (year => $yyyy, month => $mon, day => $dotm,
                          hour => $hh, minute => $mm, second => $ss,
                          time_zone => 'GMT');
  $d2->set_time_zone ($zone);
  $d2 = sprintf (";TZID=%s:%04d%02d%02dT%02d%02d%02d",
                 $zone,
                 $d2->year, $d2->month, $d2->day, 
                 $d2->hour, $d2->minute, $d2->second);
  return $d2;
}


# Scrape the sched.org ICS and fix the stupid crap in it.
# Returns a listref of ICS events.
#
sub scrape_sched($$) {
  my ($artists, $dups) = @_;

  print STDERR "$progname: scraping: $sched_url\n" if ($verbose);
  my $body = url_retry ($sched_url);

  my $sep = "\001\001\001\001";
  $body =~ s/\s+END:VCALENDAR.*$//s;
  $body =~ s/\s+(BEGIN:VEVENT)/$sep$1/gs;
  $body =~ s/\r\n/\n/gs;
  $body =~ s/\r/\n/gs;

  my @events = split (/$sep/, $body);
  shift @events;
  my @e2;

  foreach my $e (@events) {

    my ($band) = ($e =~ m@^SUMMARY:(.*?)$@mi);
    if (! $band) {
      print STDERR "$progname: no title: $e\n";
      next;
    }
    $band =~ s/\\//gs;
    $band =~ s/^\s+|\s+$//gs;

    if ($e !~ m/^CATEGORIES:BAND/mi) {
      print STDERR "$progname:   skipping non-band \"$band\"\n" 
        if ($verbose > 1);
      next;
    }

    if (! $artists->{simplify($band)}) {
      print STDERR "$progname:   skipping \"$band\"\n" if ($verbose > 1);
      next;
    }

    $e =~ s/&nbsp;/ /gs;
    $e =~ s/&[lr]squo;/\'/gs;
    $e =~ s/&[lr]dquo;/\"/gs;
    $e =~ s/&ndash;/-/gs;
    $e =~ s/&mdash;/--/gs;
    $e =~ s/&bull;/\\n\n  * /gs;
    $e =~ s/&amp;/&/gs;
    $e =~ s/\t/ /gs;
    $e =~ s/(  ) +/$1/gs;

    $e =~ s@^(DTSTART|DTEND):([^\s]*)@{ $1 . fix_sched_time($2) }@gmexi;


    my ($start) = ($e =~ m/^DTSTART.*?:(.*)$/mi);
    my $key = lc ("$band @ $start");
    if ($dups->{$key}) {
      print STDERR "$progname:   skipping dup \"$key\"\n" if ($verbose > 1);
      next;
    }
    $dups->{$key} = 1;


    my ($url) = ($e =~ m@^URL:(.*?)$@mi);
    $url =~ s/\\//gs;
    $url =~ s/^\s+|\s+$//gs;

    if (! $url) {
      print STDERR "$progname: \"$band\": no url\n" if ($verbose > 1);
    } else {
      my ($url2, $desc) = scrape_band ($band, $url);
      if (! $desc) {
        print STDERR "$progname: \"$url\": no desc!\n" if ($verbose > 1);
      } else {
        $desc = "$url2\n\n$desc" if $url2;
        $desc = ical_quote ($desc);
        if (! ($e =~ s@^(DESCRIPTION:).*?(\n[^\n])@$1$desc$2@mi)) {
          error ("unable to splice: $e");
        }
      }
    }

    push @e2, $e;
  }

  return \@e2;
}



# Update each ICS event with the street address of its venue.
# Scrapes the SXSW web site to find the addresses.
#
sub scrape_venues($) {
  my ($events) = @_;

  my %venues;

  foreach my $e (@$events) {
    my ($loc) = ($e =~ m/^LOCATION.*?:(.*)$/mi);
    if (! $loc) {
      print STDERR "$progname: no LOCATION in event: $e\n";
      next;
    }

    $loc =~ s/\(.*$//s;
    $loc =~ s/\\//gs;

    my $addr = $venues{$loc};

    if (! $addr) {
      my $url = $base_url;
      $url =~ s/\?.*$//si;
      my $v2 = $loc;
      $v2 =~ s/^The //si;
      $v2 =~ s/^\s+|\s+$//gsi;
      $v2 =~ s/ /+/gs;
      $v2 =~ s/&/%26amp%3B/gs;
      $url .= "?venue=$v2";

      print STDERR "$progname: scraping venue \"$loc\": $url\n" if ($verbose);
      my $page = url_retry ($url, 5);
    
      $page =~ s/^.*?class=\"venue-details//si;
      ($addr) = ($page =~ m@<h2>([^<>]+)@si);
      $addr = clean ($addr);
      if (! $addr) {
        print STDERR "$progname: no address for \"$loc\"\n";
        next;
      }
      print STDERR "$progname: venue: \"$loc\": $addr\n" if ($verbose > 1);
      $venues{$loc} = $addr;
    }

    # update the event

    if (! $addr) {
      print STDERR "$progname: no addr for venue: $loc\n";
    } else {
      $loc .= " ($addr)";
      $e =~ s/^(LOCATION.*?:)[^\n]*/$1$loc/mi;
    }
  }

  return \%venues;
}


# Update each ICS entry with other dates on which this band is playing,
#
sub cross_reference($) {
  my ($events) = @_;

  my %dates;
  foreach my $e (@$events) {
    my ($name)  = ($e =~ m/^SUMMARY.*?:(.*)$/mi);
    my ($start) = ($e =~ m/^DTSTART.*?:(.*)$/mi);
    my ($loc)   = ($e =~ m/^LOCATION.*?:(.*)$/mi);

    $loc =~ s/\s*\(.*$//s;
    $loc =~ s/\\//gs;
    $start .= "\t$loc";

    my $L = $dates{$name};
    my @L = $L ? @$L : ();
    push @L, $start;
    $dates{$name} = \@L;
  }

  foreach my $e (@$events) {
    my ($name) = ($e =~ m/^SUMMARY.*?:(.*)$/mi);
    my @d;
    foreach my $d (sort @{$dates{$name}}) {
      my $d2 = $d;
      my $loc = $1 if ($d2 =~ s/\t(.*)$//si);
      $loc =~ s@, .*$@@s; # omit street address here
      my ($yyyy, $mon, $dotm, $hh, $mm) = 
        ($d2 =~ m@^(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)@si);
      error ("unparsable: $d") unless $yyyy;
      $d2 = mktime (0, $mm, $hh, $dotm, $mon-1, $yyyy-1900, 0, 0, -1);
      $d2 = strftime ("%a, %I:%M %p", localtime ($d2));
      $d2 =~ s/ 0/ /gs;
      $d2 =~ s/:00 / /gs;
      $d2 .= " at $loc" if $loc;
      push @d, $d2;
    }

    # Update desc
    if (@d > 1) {
      my $d2 = ical_quote ("Multiple shows:\n\n" . join("\n", @d));
      $d2 .= "\\n\n \\n\n ";
      $e =~ s/^(DESCRIPTION.*?:)/$1$d2/mi;
    }
  }
}


# Fire, aim, ready.
#
sub scrape_all($$$) {
  my ($out, $sched_p, $stars) = @_;

  my $artists = load_bands($stars);
  my ($events1, $events2, $count1, $count2);
  my %dups;

  if ($sched_p != 0) {					# 1 or 2
    $events1 = scrape_sched ($artists, \%dups);
    $count1 = @$events1;
    # sched.org already contains venue addrs.
  }

  if ($sched_p != 1) {					# 0 or 2
    $events2 = scrape_sxsw ($artists, \%dups);
    scrape_venues ($events2);
    $count2 = @$events2;
  }

  my @events = ( ($events1 ? @$events1 : ()),
                 ($events2 ? @$events2 : ()) );
  my $events = \@events;

  cross_reference ($events);


#  if ($debug_p) {
#    print STDERR "$progname: not writing $out\n" if ($verbose);
#    return;
#  }

  print STDERR "$progname: writing $out\n" if ($verbose);
  open (my $of, '>', $out) || error ("$out: $!");
  my $c = join ("\n",
                  'BEGIN:VCALENDAR',
                  'VERSION:2.0',
                  'PRODID:-//Apple Inc.//iCal 5.0.1//EN',
                  'METHOD:PUBLISH',
                  'X-WR-TIMEZONE;VALUE=TEXT:' . $zone,
                  'CALSCALE:GREGORIAN',
                  @$events,
                  'END:VCALENDAR') . "\n";
  $c =~ s/(\n )(\n )+/$1/gs;
  $c =~ s/\n/\r\n/gs;
  print $of $c;
  close $of;

  print STDERR "$progname: sched.org events: $count1\n" if $count1;
  print STDERR "$progname: sxsw.com events: $count2\n"  if $count2;
  print STDERR "$progname: total events: " . (($count1||0) + ($count2||0)) .
    "\n";
}


sub error($) {
  my ($err) = @_;
  print STDERR "$progname: $err\n";
  exit 1;
}

sub usage() {
  print STDERR "usage: $progname [--verbose] [--debug] [--stars N] " .
    "[--sched] outfile.ics\n";
  exit 1;
}

sub main() {
  my $stars = 3;
  my $sched = 0;
  my $out;

  while ($#ARGV >= 0) {
    $_ = shift @ARGV;
    if (m/^--?verbose$/s) { $verbose++; }
    elsif (m/^-v+$/s) { $verbose += length($_)-1; }
    elsif (m/^--?q(uiet)?$/s) { $verbose = 0; }
    elsif (m/^--?debug$/s) { $debug_p++; }
    elsif (m/^--?stars$/s) { $stars = 0 + shift @ARGV; }
    elsif (m/^--?sched$/s) { $sched = 1; }
    elsif (m/^--?both$/s)  { $sched = 2; }
    elsif (m/^-./) { usage; }
    elsif (! $out) { $out = $_; }
    else { usage; }
  }
  usage unless $out;
  scrape_all ($out, $sched, $stars);
}

main();
exit 0;
