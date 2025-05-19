let root = [$env.FILE_PWD, '..'] | path join | path expand | str replace --all '\' '/';
let init_lua = ([$env.FILE_PWD, '../lua/multibuffer/init.lua'] | path join | path relative-to $env.PWD) | str replace --all '\' '/';

cd $env.FILE_PWD;
(nvim
	--clean
	$"+lua package.path = package.path .. ';($root)/lua/?/init.lua;($root)/lua/?.lua'"
	$"+cd ($env.FILE_PWD)"
	"+lua require('test')"
);
