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
   while true do
      local line, status
      input:start("input: ")
      repeat
         status, line = input:feed(io.read(1))
      until status

      if status == lineinput.DONE then
         print(string.format("\n\rline: %q\r", line))
      elseif status == lineinput.EOF then
         print("\n\rEOF\r")
         break
      elseif status == lineinput.INT then
         print(string.format("\n\rline: %q (interrupted)\r", line))
      end
   end
end)
