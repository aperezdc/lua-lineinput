#! /usr/bin/env lua
--
-- lineinput.lua
-- Copyright (C) 2016 Adrian Perez <aperez@igalia.com>
--
-- Distributed under terms of the MIT license.
--

local P = require "posix"
local bit = require "bit32"

local error, assert, tonumber = error, assert, tonumber
local setmetatable, type, pairs = setmetatable, type, pairs
local co_create, co_yield = coroutine.create, coroutine.yield
local co_resume = coroutine.resume
local t_insert, t_concat = table.insert, table.concat
local d_traceback = debug.traceback
local min, max = math.min, math.max
local sprintf = string.format

local dprintf = (function ()
   local env_var = os.getenv("LINEINPUT_DEBUG")
   if env_var and #env_var > 0 and env_var ~= "0" then
      local out = io.stderr
      return function (fmt, ...)
         out:write("[lineinput] ")
         out:write(fmt:format(...))
         out:write("\r\n")
         out:flush()
      end
   else
      return function (fmt, ...) end
   end
end)()

local unsupported_terminal = {
   dumb   = true,
   cons25 = true,
   emacs  = true,
}

local NULL      = 0
local CTRL_A    = 1
local CTRL_B    = 2
local CTRL_C    = 3
local CTRL_D    = 4
local CTRL_E    = 5
local CTRL_F    = 6
local CTRL_H    = 8
local TAB       = 9
local CTRL_K    = 11
local CTRL_L    = 12
local ENTER     = 13
local CTRL_N    = 14
local CTRL_P    = 16
local CTRL_T    = 20
local CTRL_U    = 21
local CTRL_W    = 23
local ESCAPE    = 27
local BACKSPACE = 127


-- XXX: This is very simple, recursive, and it does not handle cycles.
-- Do not use with very deeply nested tables or tables with cycles.
local function deepcopy(t)
   assert(type(t) == "table", "Parameter #1: table expected")
   local n = {}
   for name, value in pairs(t) do
      n[name] = (type(value) == "table") and deepcopy(value) or value
   end
   return n
end

local function enable_tty_raw(fd)
   if not P.isatty(fd) then
      error(P.errno(P.ENOTTY))
   end

   local term_state = P.tcgetattr(fd)
   local term_raw = deepcopy(term_state)

   -- Input modes: no break, no CR to NL, no parity check, no strip char,
   -- no start/stop output control.
   term_raw.iflag = bit.band(term_raw.iflag, bit.bnot(
         bit.bor(P.BRKINT, P.ICRNL, P.INPCK, P.ISTRIP, P.IXON)))
   -- Output modes: disable postprocessing
   term_raw.oflag = bit.band(term_raw.oflag, bit.bnot(P.OPOST))
   -- Control modes: use 8-bit characters.
   term_raw.cflag = bit.bor(term_raw.cflag, P.CS8)
   -- Local modes: echo off, canononical off, no extended functions,
   -- no signal characters (Ctrl-Z, Ctrl-C)
   term_raw.lflag = bit.band(term_raw.lflag, bit.bnot(
         bit.bor(P.ECHO, P.ICANON, P.IEXTEN, P.ISIG)))
   -- Return condition: no timeout, one byte at a time
   term_raw.cc[P.VTIME] = 0
   term_raw.cc[P.VMIN] = 1

   if P.tcsetattr(fd, P.TCSAFLUSH, term_raw) ~= 0 then
      return nil, P.errno()
   end
   return term_state
end

local function do_write_nofd(self, bytes) return self.do_write(bytes) end
local function do_flush_nofd(self) return self.do_flush() end
local function do_flush_noop(self) end

local State = {}
State.__index = State

setmetatable(State, { __call = function (self, write, flush, fd)
   local s = setmetatable({
      do_write = write,
      do_flush = flush,
      use_fd   = fd,
      buf      = "",
      prompt   = "",
      pos      = 1,     -- Current cursor position.
      cols     = -1,    -- Number of columns in the terminal.
      ttystate = false, -- Saved TTY state.
   }, State)
   if not fd then
      s.do_write = do_write_nofd
      s.do_flush = do_flush_nofd
   end
   if not flush then
      s.do_flush = do_flush_noop
   end
   return s
end })

function State:tty_write(bytes)
   -- dprintf(":write(%q)", bytes)
   return self.do_write(self.use_fd, bytes)
end

function State:tty_flush()
   self.do_flush(self.use_fd)
end

function State:tty_configure(fd)
   if self.ttystate then
      return true
   end
   if fd == nil then
      fd = self.use_fd
   end
   if type(fd) ~= "number" then
      fd = P.fileno(fd)
   end
   local state, err = enable_tty_raw(fd)
   if state then
      self.ttystate = state
      return true
   end
   return false, err
end

function State:tty_restore(fd)
   if not self.ttystate then
      return true
   end
   if fd == nil then
      fd = self.use_fd
   end
   if type(fd) ~= "number" then
      fd = P.fileno(fd)
   end
   if P.tcsetattr(fd, P.TCSAFLUSH, self.ttystate) ~= 0 then
      return false, P.errno()
   end
   self.ttystate = false
   return true
end

-- TODO: Rework
local function refresh_line(self)
   local leftpos, pos = 1, self.pos
   while #self.prompt + pos >= self.cols do
      leftpos, pos = leftpos + 1, pos - 1
   end
   local rightpos = #self.buf
   while #self.prompt + rightpos > self.cols do
      rightpos = rightpos - 1
   end
   self:tty_write(sprintf("\r%s%s\x1B[K",
      self.prompt,
      self.buf:sub(leftpos, rightpos)))
   self:tty_flush()
end

function State:beep()
   self:tty_write("\x1B[H\x1B[2J")
   self:tty_flush()
end

function State:move_left()
   if self.pos > 1 then
      self.pos = self.pos - 1
      refresh_line(self)
   end
end

function State:move_right()
   if self.pos < #self.buf then
      self.pos = self.pos + 1
      refresh_line(self)
   end
end

function State:move_home()
   if self.pos > 1 then
      self.pos = 1
      refresh_line(self)
   end
end

function State:move_end()
   if self.pos < #self.buf then
      self.pos = #self.buf
      refresh_line(self)
   end
end

function State:edit_delete()
   if #self.buf > 0 and self.pos < #self.buf then
      self.buf = self.buf:sub(1, self.pos) .. self.buf:sub(self.pos + 1, -1)
      refresh_line(self)
   end
end

function State:edit_backspace()
   if self.pos > 1 and #self.buf > 0 then
      self.buf = self.buf:sub(1, -2)
      refresh_line(self)
   end
end

function State:insert(input)
   if self.pos == #self.buf then  -- Append input.
      self.buf = self.buf .. input
   elseif self.pos == 1 then  -- Prepend input.
      self.buf = input .. self.buf
   else  -- Insert in the middle
      self.buf = self.buf:sub(1, self.pos) .. input .. self.buf:sub(self.pos + 1, -1)
   end
   self.pos = self.pos + 1
   refresh_line(self)
end

local function xpcall_traceback(errmsg)
   local tb = d_traceback(nil, nil, 2)
   return errmsg and (errmsg .. "\n" .. tb) or tb
end

function State:wrap(f, ...)
   local ok, err = self:tty_configure()
   if not ok then
      error(err)
   end
   local ok, err = xpcall(f, xpcall_traceback, ...)
   self:tty_restore()
   self:tty_write("\r\x1B[2K")
   self:tty_flush()
   if not ok then
      error(err)
   end
end

-- Response: ESC [ rows ; cols R
local cursor_position_response = "^%\x1B%[%d+;(%d+)R$"

local function query_columns(self)
   local buf = ""

   -- Read current cursor position, to restore it later
   self:tty_write("\x1B[6n")
   local saved_col
   while true do
      saved_col = buf:match(cursor_position_response)
      -- dprintf("query_columns: buf=%q, row=%s, col=%s", buf, saved_row, saved_col)
      if saved_col then
         saved_col = tonumber(saved_col)
         buf = ""  -- Clear buffer
         break
      end
      buf = buf .. co_yield()
   end

   -- Move to a column far, far away. The new position has the number of columns.
   self:tty_write("\x1B[999C\x1B[6n")
   local col
   while true do
      col = buf:match(cursor_position_response)
      -- dprintf("query_columns: buf=%q, row=%s, col=%s", buf, row, col)
      if col then
         col = tonumber(col)
         break
      end
      buf = buf .. co_yield()
   end

   -- Restore position, return number of colums
   self:tty_write(sprintf("\x1B[%dD", col - saved_col))
   dprintf("query_columns -> %d", col)
   return col
end

local function handle_input(self)
   self:tty_write("\r")
   if #self.prompt < self.cols then
      self:tty_write(self.prompt)
   end
   self:tty_flush()
   while true do
      local input = co_yield()
      local byte = input:byte()
      if byte == ENTER then
         return self.buf
      end
      if byte == CTRL_C then
         return nil  -- TODO: Return a code other than CTRL_D
      end
      if byte == BACKSPACE or input == 8 then
         self:edit_backspace()
      elseif byte == CTRL_D then
         if #self.buf > 0 then
            self:edit_delete()
         else
            return nil
         end
      elseif byte == CTRL_T then
         -- TODO: Swap current character with previous.
      elseif byte == CTRL_B then
         self:move_left()
      elseif byte == CTRL_F then
         self:move_right()
      elseif byte == CTRL_U then
         -- Delete the whole line.
         self.buf = ""
         self.pos = 1
         refresh_line(self)
      elseif byte == CTRL_K then
         -- Delete from current position to end of line.
         self.buf = self.buf:sub(1, self.pos)
         refresh_line(self)
      elseif byte == CTRL_A then
         self:move_home()
      elseif byte == CTRL_E then
         self:move_end()
      elseif byte == ESCAPE then
         -- TODO: Implement handling of escapes.
      elseif byte >= 32 then
         self:insert(input)
      end
      dprintf("buf = %q", self.buf)
   end
end

function State:start(prompt)
   if prompt then
      self.prompt = prompt
   end
   -- Reset state
   self.buf = ""
   self.pos = 1
   self.cols = -1
   self._coro = co_create(query_columns)
   assert(co_resume(self._coro, self))
end

function State:feed(input)
   dprintf("feed(%q), coro=%s", input, self._coro)
   local ok, res = co_resume(self._coro, input)
   dprintf("feed --> yielded=%s, res=%s", ok, res)
   if not ok then
      error(res)
   end
   if res and self.cols < 0 then
      dprintf("COLUMNS: %d", res)
      self.cols = res
      self._coro = co_create(handle_input)
      assert(co_resume(self._coro, self))
      return nil
   end
   return res
end


return State
