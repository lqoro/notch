use DynaLoader;
my ($lib, $fn) = @ARGV;
my $l = DynaLoader::dl_load_file($lib, 0) or die "load";
my $s = DynaLoader::dl_find_symbol($l, $fn) or die "sym";
my $x = DynaLoader::dl_install_xsub("main::f", $s);
&$x();
