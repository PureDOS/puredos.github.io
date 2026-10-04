#!/usr/bin/perl

#--------------------------------------------#
# dos-pure-github-io                         #
# License: Public Domain (www.unlicense.org) #
#--------------------------------------------#

use strict;
use Encode;
use Archive::Zip;
use LWP::UserAgent;
use Time::HiRes;
use Digest::SHA qw(sha1_hex);
use Digest::MD5 qw(md5_hex);
use MIME::Base64 qw(encode_base64);

our $outdir = "out";
our $outdatdir = "$outdir/dat";
our $cachedir = undef;
our $datzip = "https://github.com/PureDOS/DAT/archive/refs/heads/main.zip";
our $datdir = undef;

print "Finding XML and DOSC files ...\n";
my $finding_start = [Time::HiRes::gettimeofday()];
my (@files, $zipdh, $readme_md, $numxml, $numdosc);
if ($datdir)
{
	print("  Reading directory '".$datdir."' ...\n");
	opendir(DIR, "$datdir");                 push(@files, map { "$datdir/".$_                 } grep { /\.(xml|md)$/i } readdir(DIR)); closedir(DIR);
	opendir(DIR, "$datdir/dosc");            push(@files, map { "$datdir/dosc/".$_            } grep { /\.dosc$/i     } readdir(DIR)); closedir(DIR);
	opendir(DIR, "$datdir/unverified");      push(@files, map { "$datdir/unverified/".$_      } grep { /\.xml$/i      } readdir(DIR)); closedir(DIR);
	opendir(DIR, "$datdir/unverified/dosc"); push(@files, map { "$datdir/unverified/dosc/".$_ } grep { /\.dosc$/i     } readdir(DIR)); closedir(DIR);
}
else
{
	if ($cachedir) { mkdir($cachedir); }
	my $datzip = GetURL($datzip, qr/\.xml$/);
	unless ($datzip) { die "Failed to get ZIP from '".$datzip."'\n"; }
	open($zipdh, "+<:raw", \$datzip) or die;
	my $zip = Archive::Zip->new;
	$zip->readFromFileHandle($zipdh);
	@files = $zip->membersMatching('\.([xX][mM][lL]|[dD][oO][sS][cC]|[mM][dD])$');
}
print "Finding XML and DOSC files done (".(Time::HiRes::tv_interval($finding_start)*1000)."ms)\n\n";

print "Parsing DAT XML and DOSC files ...\n";
my $releases_start = [Time::HiRes::gettimeofday()];
our (%gamedb);
mkdir($outdir);
foreach my $m (@files)
{
	my $mname = (ref $m ? $m->fileName() : $m);
	my $mcontents = (ref $m ? scalar($m->contents()) : do { open my $fh, '<:raw', $mname; local $/; <$fh> });
	if ($mname =~ /\.xml$/)
	{
		print "  Parsing DAT: $mname\n";
		my ($dat, $cut_r, $unverified) = ($mcontents, (index($mcontents, "\r") == -1 ? 0 : 1), ($mname =~ /PureDOSDAT_Unverified/));
		for (my ($i, $iNext, $iEnd, $ingame, $inheader, $inrom, $rommeta, $x, $y, $z, $g, @filearr, @linkarr) = (0, 0, length($dat)); $i < $iEnd; $i = ($iNext == -1 ? $iEnd : $iNext + 1))
		{
			$iNext = index($dat, "\n", $i);
			while (index($dat, "\t", $i) == $i) { $i++; }
			my $ln = substr($dat, $i, ($iNext == -1 ? $iEnd : ($iNext - $cut_r)) - $i);
			if ($ingame)
			{
				if ($ln =~ /^<rom name="([^\"]+)" size="(\d+)" crc="([^\"]+)" md5="([^\"]+)" sha1="([^\"]+)"(?: date="(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)"|)(?: data="([^\"]+)"|)(\/?)>$/)
				{
					my ($fname, $fsize, $fcrc, $fmd5, $fsha1, $fyear,$fmon,$fday,$fhour,$fmin,$fsec, $fdata, $romslash) = ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13);
					push(@filearr, '["'.$fname.'",'.int($fsize).','.int($fyear-1900).','.int($fmon).','.int($fday).','.int($fhour).','.int($fmin).','.int($fsec).',"'.lc($fcrc).'","'.lc($fmd5).'","'.lc($fsha1).'"'.($fdata ? ',"'.$fdata.'"' : ($romslash ? '' : ',0')).']');
					$inrom = !$romslash;
				}
				elsif ($ln =~ /^<source type="([^\"]+)" frames="([^\"]+)"(?: pregap="([^\"]+)"|)(?: omitted_pregap="([^\"]+)"|) duration="([^\"]+)"(?: size="([^\"]+)" crc="([^\"]+)" md5="([^\"]+)" sha1="([^\"]+)" in_zeros="([^\"]+)" out_zeros="([^\"]+)" quality="([^\"]+)"|)(?: non_silence_pregap="([^\"]+)"|)\/>$/ && $inrom)
				{
					my ($stype, $sframes, $spregap, $somittedpregap, $sduration, $ssize, $scrc, $smd5, $ssha1, $sinzeros, $soutzeros, $squality, $snonsilencepregap) = ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13);
					if (!$rommeta) { $rommeta = 'S'; } elsif (substr($rommeta, 0, 1) ne 'S') { die "Mixing child-tags of <rom> in '$ingame' ($rommeta)\n"; }
					$rommeta .= "#$stype#$sframes#$spregap#$somittedpregap#$sduration#$ssize#$scrc#$smd5#$ssha1#$sinzeros#$soutzeros#$squality#$snonsilencepregap";
				}
				elsif ($ln =~ /^<track number="([^\"]+)" type="([^\"]+)" frames="([^\"]+)"(?: pregap="([^\"]+)"|)(?: omitted_pregap="([^\"]+)"|) duration="([^\"]+)" size="([^\"]+)" crc="([^\"]+)" md5="([^\"]+)" sha1="([^\"]+)"(?: in_zeros="([^\"]+)" out_zeros="([^\"]+)"|)(?: trimmed_crc="([^\"]+)"|)\/>$/ && $inrom)
				{
					my ($tnumber, $ttype, $tframes, $tpregap, $tomittedpregap, $tduration, $tsize, $tcrc, $tmd5, $tsha1, $tinzeros, $toutzeros, $ttrimmedcrc) = ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13);
					if (!$rommeta) { $rommeta = 'T'; } elsif (substr($rommeta, 0, 1) ne 'T') { die "Mixing child-tags of <rom> in '$ingame' ($rommeta)\n"; }
					$rommeta .= "#$tnumber#$ttype#$tframes#$tpregap#$tomittedpregap#$tduration#$tsize#$tcrc#$tmd5#$tsha1#$tinzeros#$toutzeros#$ttrimmedcrc";
				}
				elsif ($ln =~ /^<patch data="([^\"]+)" size="([^\"]+)" crc="([^\"]+)" md5="([^\"]+)" sha1="([^\"]+)"\/>$/ && $inrom)
				{
					my ($pdata, $psize, $pcrc, $pmd5, $psha1) = ($1, $2, $3, $4, $5);
					if (!$rommeta) { $rommeta = 'P'; } elsif (substr($rommeta, 0, 1) ne 'P') { die "Mixing child-tags of <rom> in '$ingame' ($rommeta)\n"; }
					$rommeta .= "#$pdata#$psize#$pcrc#$pmd5#$psha1";
				}
				elsif ($ln =~ /^<\/rom>$/ && $inrom)
				{
					if ($rommeta) { substr($filearr[-1], -1) = ",\"$rommeta\"]"; $rommeta = ''; }
					$inrom = 0;
				}
				elsif ($ln =~ /^<\/game>$/)
				{
					if (!@filearr) { print STDERR "Error: No file in '$ingame'\n"; next; }
					#my $filars = join(",", sort { $a =~ s/(\d+)/substr("0000000".$1, -8)/ge; $b =~ s/(\d+)/substr("0000000".$1, -8)/ge; "\L$a" cmp "\L$b" } @filearr); # numerically sort numbers in file names
					my $filars = join(",", @filearr); # keep order as is in DAT
					$filars =~ s/\\/\//g;$filars=~s/\&amp;/\&/g;$filars=~s/\&\#(\d+);/pack("C",$1)/eg;$filars=~s/\&lt;/</g;$filars=~s/\&quot;/\"/g;$filars=~s/\&gt;/>/g;$filars=~s/\&apos;/\'/g;
					if (index($filars, "\x7F") != -1) { die "    7F byte in file list of '$ingame'\n\n$filars"; }
					if (index($filars, "\xFF") != -1) { die "    FF byte in file list of '$ingame'\n\n$filars"; }

					if ($ingame =~ /^(The|An|A) /i) { print STDERR "Warning: Entry '$ingame' starts with a common article '$1' (should be '... ,$1')\n"; }
					if ($ingame =~ /:|~/) { print STDERR "Warning: Entry '$ingame' contains a colon\n"; }
					my $expectdesc = $ingame; $expectdesc =~ s/ - /\: /; $expectdesc =~ s/^(.*?), (The|An|A)/\2 \1/;
					my $expectname = $g->{description}.' ('.$g->{year}.') ('.$g->{developer}.')'.($g->{variant}?' ('.$g->{variant}.')' : '');
					if ($expectdesc ne $expectname && !$unverified) { print STDERR "Warning: Game name '$expectdesc' doesn't match 'DESCRIPTION (YEAR) (DEVELOPER) (VARIANT)' template\nWarning: expected  '$expectname')\n"; }

					if ($g->{parent} && index($filars, '["'.$g->{parent}.'.parent",0,') < 0) { print STDERR "Warning: Entry '$ingame' has a <parent> element but no .parent file ('".$g->{parent}."' not in files: $filars)\n"; }
					elsif (index($filars, '.parent",0,') >= 0 && !$g->{parent}) { print STDERR "Warning: Entry '$ingame' has a .parent file but not a <parent> element (Files: $filars)\n"; }
					elsif ($g->{parent} && index($filars, '.parent",', index($filars, '.parent",')+1) >= 0) { print STDERR "Warning: Entry '$ingame' has multiple .parent files (Files: $filars)\n"; }
					if (index($filars, '.savename",') >= 0 && index($filars, '.savename",', index($filars, '.savename",')+1) >= 0) { print STDERR "Warning: Entry '$ingame' has multiple .savename files (Files: $filars)\n"; }

					$g->{files} = $filars;
					$g->{links} = (@linkarr ? join(",", @linkarr) : 0);
					if ($g->{parent}) { die "    Parent '$g->{parent}' of '$ingame' doesn't end with '.dosz'\n" unless $g->{parent} =~ s/\.dosz$//; push(@{$gamedb{$g->{parent}}->{children}}, $ingame); }
					($ingame, $g, @filearr, @linkarr) = (0);
				}
				elsif ($ln =~ /^<(description|year|comment|comment_dosc|developer|parent|variant)>([^<]+)<\/\1>$/)
				{
					($x, $y) = ($1, $2);
					metafield:
					die "    Duplicate $x field in '$ingame'!\n" if $g->{$x};
					$y=~s/\&amp;/\&/g;$y=~s/\&\#(\d+);/pack("C",$1)/eg;$y=~s/\&lt;/</g;$y=~s/\&quot;/\"/g;$y=~s/\&gt;/>/g;$y=~s/\&apos;/\'/g;
					$g->{$x} = $y;
				}
				elsif ($ln eq "<comment>")      { my $j = index($dat, "</", $iNext); die if substr($dat, $j, 10) ne "</comment>";      ($x, $y) = ("comment",      substr($dat, $iNext+1, $j-$iNext-1)); $iNext = $j + 10 + $cut_r; goto metafield; }
				elsif ($ln eq "<comment_dosc>") { my $j = index($dat, "</", $iNext); die if substr($dat, $j, 15) ne "</comment_dosc>"; ($x, $y) = ("comment_dosc", substr($dat, $iNext+1, $j-$iNext-1)); $iNext = $j + 15 + $cut_r; goto metafield; }
				elsif ($ln =~ /^<media_link>([^<]+)<\/media_link>$/) { ($x, $y, $z) = ("media", "", $1); goto metalink; }
				elsif ($ln =~ /^<link type="([^\"]+)"(?: name="([^\"]+)"|)>([^<]+)<\/link>$/)
				{
					($x, $y, $z) = ($1, $2, $3);
					metalink:
					$z=~s/\&amp;/\&/g;$z=~s/\&\#(\d+);/pack("C",$1)/eg;$z=~s/\&lt;/</g;$z=~s/\&quot;/\"/g;$z=~s/\&gt;/>/g;$z=~s/\&apos;/\'/g;
					$z =~ s/\"/\\\"/g;
					push(@linkarr, '["'.$x.'","'.$z.'"'.($y ? ',"'.$y.'"' : '').']');
				}
				else { die "    Unknown XML game line [$ln]"; }
			}
			elsif ($ln =~ /^<game name="([^\"]+)\.(dosz|dosx|chd)">$/ && !$ingame)
			{
				($ingame, @filearr, @linkarr) = ($1);
				if (index($ingame, "\x7F") != -1) { die "    7F byte in name '$ingame'\n"; }
				if (index($ingame, "\xFF") != -1) { die "    FF byte in name '$ingame'\n"; }
				if (index($ingame, "\"")   != -1) { die "    Double quote in name '$ingame'\n"; }
				if (index($ingame, "\\")   != -1) { die "    Backslash in name '$ingame'\n"; }
				if (index($ingame, "/")    != -1) { die "    Slash in name '$ingame'\n"; }
				$ingame=~s/\&amp;/\&/g;$ingame=~s/\&\#(\d+);/pack("C",$1)/eg;$ingame=~s/\&lt;/</g;$ingame=~s/\&quot;/\"/g;$ingame=~s/\&gt;/>/g;$ingame=~s/\&apos;/\'/g;
				$g = $gamedb{$ingame} || ($gamedb{$ingame} = {});
				if ($g->{files}) { die "    Duplicate game '$ingame'!\n"; }
				if ($2 ne "dosz") { $g->{ext} = $2; }
				if ($unverified) { $g->{unverified} = 1; }
			}
			elsif ($inheader == 1)
			{
				#if ($ln =~ /<name>(.*?)<\/name>/) { print "    Parsing DAT Name: $1\n"; }
				if ($ln eq "</header>") { $inheader = 2; }
			}
			elsif ($ln eq "<header>" && !$inheader) { $inheader = 1; }
			elsif ($ln eq '<datafile>') {}
			elsif ($ln eq '</datafile>') { $inheader = 0; }
			elsif ($ln eq '<?xml version="1.0"?>') {}
			elsif ($ln eq '<!DOCTYPE datafile PUBLIC "-//Logiqx//DTD ROM Management Datafile//EN" "http://www.logiqx.com/Dats/datafile.dtd">') {}
			elsif ($ln eq '') {}
			else { die "    Unknown XML root line [$ln] ".substr($dat, $i-100, 300); }
		}
		$numxml++;
	}
	elsif ($mname =~ /([^\/]*)\.dosc$/)
	{
		my ($ingame, $dosczip, @doscfiles) = ($1, Archive::Zip->new);
		open(my $doscdh, "+<:raw", \$mcontents) or die;
		$dosczip->readFromFileHandle($doscdh);
		foreach my $doscm ($dosczip->members())
		{
			my ($c, $sz) = (scalar($doscm->contents()), $doscm->uncompressedSize());
			if (!$sz && $doscm->lastModTime() == 851437920 && substr($doscm->fileName(), -1) eq '/') { next; } # exclude directories with the torrentzip default date/time
			my ($fname, $fsize, $fcrc, $fmd5, $fsha1, $fdata) = ($doscm->fileName(), $sz, $doscm->crc32String(), md5_hex($c), sha1_hex($c), (($sz && $sz <= 1024) ? encode_base64($c, '') : 0));
			my ($fsec, $fmin, $fhour, $fday, $fmon, $fyear) = localtime($doscm->lastModTime());
			push(@doscfiles, '["'.$fname.'",'.int($fsize).','.int($fyear).','.int($fmon+1).','.int($fday).','.int($fhour).','.int($fmin).','.int($fsec).',"'.lc($fcrc).'","'.lc($fmd5).'","'.lc($fsha1).'"'.($fdata ? ',"'.$fdata.'"' : '').']');
		}
		close($doscdh);
		if ($gamedb{$ingame}->{dosc}) { die "Duplicated DOSC for $ingame\n"; }
		$gamedb{$ingame}->{dosc} = join(",", @doscfiles);
		$numdosc++;
	}
	elsif ($mname =~ /README\.md$/)
	{
		$readme_md = $mcontents;
	}
}
if ($zipdh) { close($zipdh); }
print "Parsing $numxml DAT XMLs and $numdosc DOSC files done (".(Time::HiRes::tv_interval($releases_start)*1000)."ms)\n\n";

if ($readme_md)
{
		print "Converting Markdown README to '$outdir/index.html' with template index.html ...\n";
		my ($markdown_start, $html, $lastmode, $indent) = ([Time::HiRes::gettimeofday()], "", 0);
		foreach my $ln (split(/^/, $readme_md."\n"))
		{
			my ($linemode);
			chomp($ln);
			if ($ln =~ s/^\s*\`\`\`.*//) # code paragraph
			{
				$linemode = ($lastmode eq "pre" ? "" : "pre");
			}
			elsif ($lastmode eq "pre") { $linemode = "pre"; } # continue pre
			elsif ($ln =~ /^(\#+) (.*)/) # header
			{
				my ($ttl, $aname, $len) = ($2, lc($2), length($1)+1);
				$aname =~ s/\s/-/g;
				$ln = "<a name=\"$aname\"></a><h$len>$ttl</h$len>";
			}
			elsif ($ln =~ /^> (.*)/) # quote
			{
				$ln = "<cite>$1</cite>";
			}
			elsif ($ln) # text paragraph
			{
				if ($lastmode ne "br" && $lastmode ne "p") { $html .= "\n"; }
				$linemode = "p";
				$ln =~ s!  +$! <br />!;
			}
			elsif ($lastmode eq "br") { next; } # merge conscecutive empty lines
			else { $linemode = "br"; } # empty line

			if ($linemode ne $lastmode)
			{
				if ($linemode eq "p") { $ln = "<p>$ln"; }
				if ($lastmode eq "p") { $html .= "</p>"; }
				if ($linemode eq "pre") { $ln = "<pre>$ln"; }
				if ($lastmode eq "pre") { $ln .= "</pre>"; }
				$lastmode = $linemode;
			}
			$html .= ($html ? "\n" : "").$ln;
		}
		$html =~ s!\[([^\]]+)\]\(([^)(]*(?:\([^)(]*\)[^)(]*)*)\)!<a href="$2">$1</a>!g;
		$html =~ s!<a href=\"../../..!<a href=\"https://github.com/PureDOS!g;
		$html =~ s!<a href="([^\:\"\#][^\:\"]*)"!<a href="https://github.com/PureDOS/DAT/tree/main/$1"!g;
		$html =~ s!`([^`]+)`!<code>$1</code>!g;
		$html =~ s/\&/\&amp;/g;
		my $res = do { open my $fh, '<:raw', "index.html"; local $/; <$fh> };
		$res =~ s/<<<README>>>/$html/;
		open(OUT, ">:raw", "$outdir/index.html"); print OUT $res; close(OUT);
		print "Converting Markdown README done (".(Time::HiRes::tv_interval($markdown_start)*1000)."ms)\n\n";
}

print "Building JS data set into '$outdatdir'...\n";
my $output_start = [Time::HiRes::gettimeofday()];
if (!mkdir($outdatdir))
{
	opendir(DIR, $outdatdir);
	my @files = readdir(DIR);
	closedir(DIR);
	foreach my $f (@files) { if (substr($f, 0, 1) ne ".") { unlink("$outdatdir/$f"); } }
}
my $ranges;
my @gamedb_names = sort { "\L$a".$a cmp "\L$b".$b } keys %gamedb;
for (my ($i, $ilast, $outlen, $prevgame, $lastsplit, $nextrange, @out) = (0, @gamedb_names-1, 0, "", 0, 0); $i <= $ilast; $i++)
{
	my $ingame = $gamedb_names[$i];
	if (uc(substr($ingame, 0, 4)) ne uc(substr($prevgame, 0, 4)))
	{
		$lastsplit = @out;
	}
	$prevgame = $ingame;

	my $g = $gamedb{$ingame};
	my ($files, $links, $dosc, $comment, $comment_dosc, $ext, $children, $unverified) = ($g->{files}, $g->{links}, $g->{dosc}, $g->{comment}, $g->{comment_dosc}, $g->{ext}, $g->{children}, $g->{unverified});
	if (!$files) { print STDERR "Error: Game '$ingame' has no files (maybe a lone DOSC or a referenced parent that doesn't exist? DOSC: ".($dosc ? "Yes" : "No")." - Children: ".($children ? scalar(@{$children}) : '0').")\n"; next; }
	while ($comment      && $comment      !~ /(^|\n)[^\t]/) { $comment      =~ s/(^|\n)\t/\1/gs; } #evenly de-indent tabs
	while ($comment_dosc && $comment_dosc !~ /(^|\n)[^\t]/) { $comment_dosc =~ s/(^|\n)\t/\1/gs; } #evenly de-indent tabs
	$comment      =~ s/\r//g; $comment      =~ s/[\n\t]+$//; $comment      =~ s/\\/\\\\/g; $comment      =~ s/\n/\\n/g; $comment      =~ s/\t/\\t/g; $comment      =~ s/\"/\\\"/g;
	$comment_dosc =~ s/\r//g; $comment_dosc =~ s/[\n\t]+$//; $comment_dosc =~ s/\\/\\\\/g; $comment_dosc =~ s/\n/\\n/g; $comment_dosc =~ s/\t/\\t/g; $comment_dosc =~ s/\"/\\\"/g;

	my $line = "[\"$ingame\",".($comment ? "\"$comment\"":"0").",".($comment_dosc?"\"$comment_dosc\"":"0").",".($links?"[$links]":"0").",[".$files."],".($dosc?"[$dosc]":"0")
		.(($children || $ext || $unverified) ? ',{'.($children ? "c:[\"".join("\",\"", @{$children})."\"]," : '').($ext ? "e:\"$ext\"," : '').($unverified ? "u:1" : '').'}' : '')."],\n";
	push(@out, $line);
	$outlen += length($line);

	my $isend = ($i == $ilast);
	if (($outlen > 512*1024 && $lastsplit) || $isend)
	{
		my @block = splice(@out, 0, ($isend ? int(@out) : $lastsplit));
		#print "    Writing "."dat_".$nextrange.".js"."\n";
		open(OUT, ">:raw", "$outdatdir/dat_$nextrange.js");
		print OUT "document.OnDATData([\n";
		print OUT join("", @block);
		print OUT "]);";

		$ranges .= $nextrange.($isend ? "" : ",");
		$nextrange = unpack("N", uc(substr($block[-1], 2, 4))."\0\0\0\0") + 1;
		$lastsplit = 0;
		$outlen = length(join("", @out));
	}
}
print "Building JS data set done (".(Time::HiRes::tv_interval($output_start)*1000)."ms)\n\n";

print "Creating '$outdatdir/index.html' from dat.html ...\n";
my $index_start = [Time::HiRes::gettimeofday()];
open(IN, "<:raw", "dat.html");
open(OUT, ">:raw", "$outdatdir/index.html");
while (<IN>)
{
	my $line = $_;
	$line =~ s/<<<RANGES>>>/$ranges/;
	print OUT $line;
}
close(OUT);
close(IN);
print "Creating index.html done (".(Time::HiRes::tv_interval($index_start)*1000)."ms)\n\n";

sub GetURL
{
	my ($path, $bin) = ($_[0], "");
	if ($cachedir && $path =~ /[^\\\/]+$/ && -e $cachedir."/".(($path =~ /([^\\\/]+)$/)[0]))
	{
		$path = $cachedir."/".(($path =~ /([^\\\/]+)$/)[0]);
		print("  Loading cached '".$path."' ...\n");
		open(IN,"<:raw", $path); $bin.= $_ while <IN>; close(IN);
	}
	elsif (index($path, "://") > 0)
	{
		for (my $retry = 0;; $retry++)
		{
			print("  Downloading '".$path."' ".($retry ? "(Retry $retry)" : "")."...\n");
			my $ua = LWP::UserAgent->new(send_te => 0, ssl_opts => { verify_hostname => 0 }, protocols_allowed => ['http','https'],);
			my $req = HTTP::Request->new('GET', $path, [ 'Accept-Encoding' => scalar(HTTP::Message::decodable) ]); # use gzip/zlib if possible
			#print "REQUEST: \n-----------------------\n".$ua->prepare_request($req)->as_string."\n----------------------------\n";#exit;
			my $res = $ua->request($req);
			#print "RESPONSE: \n-----------------------\n".$res->as_string."\n----------------------------\n";#exit;
			$bin =  $res->decoded_content(charset => 'none');
			if ($res->code >= 200 && $res->code <= 299) { last; }
			if ($retry == 10) { die "Download of '$path' failed\n"; }
		}
	}
	else
	{
		print("  Loading '".$path."' ...\n");
		open(IN,"<:raw", $path); $bin.= $_ while <IN>; close(IN);
	}

	if ($cachedir && index($path, $cachedir) != 0)
	{
		my $outpath = $cachedir."/".(($path =~ /([^\\\/]+)$/)[0]);
		print("  Caching '".$path."' to '".$outpath."' ...\n");
		open(OUT,">:raw", $outpath); print OUT $bin; close(OUT);
	}
	return $bin;
}
