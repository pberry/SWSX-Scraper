# This code is written by Jamie Zawinski
## It says so in the copyright banner at the top of the source file.
### Here it is again

Copyright © 2012 Jamie Zawinski <jwz@jwz.org>

Permission to use, copy, modify, distribute, and sell this software and its
documentation for any purpose is hereby granted without fee, provided that
the above copyright notice appear in all copies and that both that
copyright notice and this permission notice appear in supporting
documentation.  No representations are made about the suitability of this
software for any purpose.  It is provided "as is" without express or 
implied warranty.

## How To Use This

You will need to have perl installed.  If you don't have perl installed, perhaps this isn't the best tool for you right now.  You will also need DateTime installed (which isn't by default in OS X).

`sudo cpan install DateTime`

Now that we have that little task out of the way, you can run the script:

`perl sxsw-scraper.pl --stars 3 outfile.ics`

This will spit out an iCal file that you can import into your calendar application of choice and you will be ready for SxSW!  Hooray!

## Huh?

So, this little script is really only going to work if you rate your tracks in iTunes.  If you don't do that, don't even bother trying to use this because it will not do anything for you.

Why?  Because Jamie wrote it for himself and that's how he does things.  If it doesn't work for you that's a bummer, but it's how it is.