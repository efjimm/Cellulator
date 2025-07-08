zc.events = {
  register = function(self, name, arg)
    if self[name] then return end
    self[name] = arg or {}
  end,

  emit = function(self, name, ...)
    if not self[name] then error('Invalid event') end
    if self[name].dispatch then
      return self[name].dispatch(...)
    else
      return self:_default_dispatch(name, ...)
    end
  end,

  subscribe = function(self, name, handler, ...)
    if self[name].subscribe then
      self[name].subscribe(name, handler, ...)
    else
      self:_default_subscribe(name, handler, ...)
    end
  end,

  _default_subscribe = function(self, name, handler, ...)
    if not name then error('Invalid name') end
    if not handler then error('Invalid handler') end

    if not self[name].handlers then self[name].handlers = {} end
    table.insert(self[name].handlers, handler)
  end,

  _default_dispatch = function(self, name, ...)
    if not self[name].handlers then return end
    for i,v in pairs(self[name].handlers) do
      if v(...) == false then return false end
    end
    return true
  end,
}

-- Emitted after startup but before the file specified on the command line is loaded.
zc.events:register('Init')
-- Emitted after startup and after the file specified on the command line is loaded.
zc.events:register('Start')
-- Emitted whenever the user manually sets a single cell value.
zc.events:register('SetCell')
-- Emitted whenever the file path of a sheet is updated.
zc.events:register('UpdateFilePath')
