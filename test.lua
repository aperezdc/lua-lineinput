#! /usr/bin/env lua
--
-- lnmain.lua
-- Copyright (C) 2016 Adrian Perez <aperez@igalia.com>
--
-- Distributed under terms of the MIT license.
--

local lineinput = require "lineinput"

local input = lineinput(io.stdout.write, io.stdout.flush, io.stdout)
input:wrap(function ()
   local line
   -- repeat
      input:start("input: ")
      repeat
         line = input:feed(io.read(1))
      until line
      print("\n\rline: " .. line .. "\r")
   -- until #line == 0
end)
