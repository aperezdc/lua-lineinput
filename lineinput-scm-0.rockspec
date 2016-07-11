package = "lineinput"
version = "scm-0"
description = {
   summary = "Terminal line-based input",
   homepage = "https://github.com/aperezdc/lua-lineinput",
   license = "MIT/X11",
}
source = {
   url = "git://github.com/aperezdc/lua-lineinput",
}
dependencies = {
   "lua >= 5.1",
   "luaposix ~> 33",
   "dromozoa-utf8",
   "wcwidth",
   "bit32",
}
build = {
   type = "builtin",
   lineinput = "lineinput.lua",
}
