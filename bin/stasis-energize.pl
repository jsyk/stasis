#!/usr/bin/perl

use strict;
use warnings;
use Sys::Hostname;
use FindBin qw($Bin);
use Digest::SHA; # qw(sha1 sha1_hex sha1_base64 ...);
use Digest::MD5;
use File::Path qw(make_path);
use File::Copy;

use constant RECSEP => "\0\n";

my $host = hostname;
my $sroot = "$Bin/..";
# my $curdt = DateTime->now;
my ($second,$minute,$hour,$mday,$month,$year,$wday,$yday,$isdst) = localtime time;

# my $viewname = sprintf("%s/%d-%02d-%02d_%02d-%02d-%02d", 
#         $host, $curdt->year, $curdt->month, $curdt->day, 
#         $curdt->hour, $curdt->minute, $curdt->second);
my $viewname = sprintf("%s/%d-%02d-%02d_%02d-%02d-%02d", 
        $host, $year+1900, $month+1, $mday, 
        $hour, $minute, $second);
my $fullviewname = $sroot . '/views/' . $viewname;

my $hashcache = {};
my $newhashcache = {};

my $count_newfiles = 0;
my $count_newdtsize = 0;

###################################################################################
sub SplitToParts
{
    my $str = shift;
    my $plen = shift;
    my $r = '';
    
    for (my $i = 0; $i < length($str); $i += $plen) {
        $r = $r . '/' . substr($str, $i, $plen);
    }
    return $r;
}

###################################################################################
sub SplitDigestToDir
{
    my $str = shift;
    my $r = substr($str, 0, 2) . '/' . substr($str, 2, 4) . '/' . substr($str, 6);
    return $r;
}

###################################################################################
sub TakeInFile #($dirname, $name)
{
    my $dirname = shift;
    my $name = shift;
    my $fullname = "$dirname/$name";

    my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
        $atime,$mtime,$ctime,$blksize,$blocks) = stat($fullname);

    # can the file be opened at all?
    my $fh;
    if (not open($fh, '<', $fullname)) {
	# no; just skip it...
	print "Error opening '$fullname', skipped.\n";
	return (0, 0);
    }
    close($fh);
    
    my $digest;
    my $fromcache = 0;
    # try to find digest in the cache
    if (exists $hashcache->{$fullname}) {
        my ($c_mtime, $c_size, $c_digest) = @{ $hashcache->{$fullname} };
        if ($c_mtime == $mtime and $c_size == $size) {
            $digest = $c_digest;
            $fromcache = 1;
        }
    }
    
    if (not defined($digest)) {
        # compute the digest of the file the hard way
        my $sha = Digest::SHA->new('256');
        $sha->addfile($fullname);
        $digest = $sha->hexdigest;
    }
#     my $md5 = Digest::MD5->new;
#     open my $fnamefh, $fullname or die $!;
#     $md5->addfile($fnamefh);
#     close $fnamefh;
#     my $digest = $md5->hexdigest;
    
    #my $prntstr = "    '$name': $fromcache, $digest";
    #print "$prntstr\033[K\033[" . length($prntstr) . "D";
    
    my $hdir = SplitDigestToDir($digest);
    #print "      $hdir\n";
    
    my $fullhdir = "$sroot/chamber/by-hash/$hdir";
    my $foundchamber = 0;
    if (-d $fullhdir) {
        # already exists in the chamber
        $foundchamber = 1;
    } else {
        # a new file
        make_path($fullhdir);
        copy($fullname, $fullhdir . '/body');
    }
    
    make_path($fullviewname . '/' . $dirname);
    link($fullhdir . '/body', $fullviewname . '/' . $fullname);
    
    open my $nmlist, '>>' . $fullhdir . '/names' or die $!;
    print $nmlist $viewname . $fullname . RECSEP;
    close $nmlist;
    
    $newhashcache->{$fullname} = [$mtime, $size, $digest];
    
    return ($fromcache, $foundchamber);
}

###################################################################################
sub ScanDir #($dirname)
{
    my $dirname = shift;
    #print "$dirname";
    opendir my $dirfh, $dirname or die "$!: $dirname\n";
    my @names = readdir($dirfh) or die $!;
    close $dirfh;
    
    my $num_files = 0;
    my $num_incache = 0;
    my $num_inchamber = 0;
    
    foreach my $name (@names) {
        next if ($name eq ".");   # skip the current directory entry
        next if ($name eq "..");  # skip the parent  directory entry
        my $fullname = "$dirname/$name";
        
        if (-d $fullname) {            # is this a directory?
            #print "found a directory: $name\n";
            ScanDir($fullname);
            next;                  # can skip to the next name in the for loop 
        }
        
        my @s = TakeInFile($dirname, $name);
        $num_files++;
        $num_incache += $s[0];
        $num_inchamber += $s[1];
    }
    
    print "$dirname   ||  Files: $num_files / $num_incache / $num_inchamber\n";
}

###################################################################################
sub SaveHashCache #(hcache ref, hcfname)
{
    my $hcache = shift;
    my $hcfname = shift;
    
    open my $hcfh, '>' . $hcfname or die $!;
    for my $fullname (keys %$hcache) {
        my @vals = @{ $hcache->{$fullname} };
        print $hcfh $fullname . RECSEP . join(' ', @vals) . RECSEP;
    }
    close $hcfh;
}

###################################################################################
sub LoadHashCache #(hcfname)
{
    my $hcfname = shift;
    my $hcache = {};
    
    if (-e $hcfname) {
        open my $hcfh, $hcfname or die $!;
        $/ = RECSEP;
        while (<$hcfh>) {
            chomp;
            my $fullname = $_;
            $_ = <$hcfh>;
            chomp;
            my @vals = split(/ /, $_);
            $hcache->{$fullname} = \@vals;
        }
        $/ = "\n";
        close $hcfh;
    }
    return $hcache;
}

###################################################################################

umask(0);       # make everything we create read-writable by all
$hashcache = LoadHashCache("$sroot/chamber/by-name/$host/hashcache");

my $cfgdir = "$sroot/config/by-host/$host";
opendir my $dirfh, $cfgdir or die "$!: $cfgdir\n";
my @cfgnames = readdir($dirfh) or die $!;
close $dirfh;

# list of dirs from config that shall be scanned
my @scandirs = ();

foreach my $cfgfn (@cfgnames) {
    open my $cfgfh, "$cfgdir/$cfgfn" or die $!;
    while (<$cfgfh>) {
        chomp;
        my $dirname = $_;
        push @scandirs, $dirname;
        print "SCAN: $dirname\n";
    }
    close $cfgfh;
}

foreach my $dirname (@scandirs) {
    ScanDir($dirname);
}

make_path("$sroot/chamber/by-name/$host");
SaveHashCache($newhashcache, "$sroot/chamber/by-name/$host/hashcache");

