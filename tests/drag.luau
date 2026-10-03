-- Run with: lune run tests/drag.luau
local fs = require('@lune/fs')
local luau = require('@lune/luau')
local capture
local scope
local scopes = {}
local vide = {
    create = function()
        return function(properties)
            properties.Destroy = function(self) self.destroyed = true end
            capture = properties
            return properties
        end
    end,
    cleanup = function(item) table.insert(scope, item) end,
    source = function(value)
        return function(...)
            if select('#', ...) > 0 then value = ... end
            return value
        end
    end,
    root = function(callback)
        local cleanups = {}
        scope = cleanups
        callback()
        scope = nil
        local closed = false
        local function close()
            if closed then return end
            closed = true
            for _, item in cleanups do
                if type(item) == 'function' then item()
                elseif item.Disconnect then item:Disconnect()
                else item:Destroy() end
            end
        end
        table.insert(scopes, close)
        return close
    end,
}
local overlay = luau.load(fs.readFile('src/Overlay.luau'):gsub('%f[%w]const%f[%W]', 'local'), {
    environment = {
        require = function(path) return if path == './vide' then vide else {} end,
        Enum = { UserInputState = { End = 'End', Cancel = 'Cancel' },
                 UserInputType = { MouseMovement = 'MouseMovement', MouseButton1 = 'MouseButton1' } },
        UDim2 = { fromScale = function() return {} end },
        Vector2 = { new = function(x, y) return { X = x, Y = y } end },
    },
})()
local function point(x, y)
    return setmetatable({ X = x, Y = y }, { __sub = function(a, b) return point(a.X - b.X, a.Y - b.Y) end })
end
overlay.setLayer({ AbsolutePosition = point(0, 0) })

local function press(state)
    local input = { UserInputState = state or 'Begin' }
    local connection
    function input:GetPropertyChangedSignal(property)
        assert(property == 'UserInputState')
        return { Connect = function(_, callback)
            connection = { Connected = true }
            function connection:Disconnect() self.Connected = false end
            connection.callback = callback
            return connection
        end }
    end
    function input:setState(value)
        self.UserInputState = value
        if connection.Connected then connection.callback() end
    end
    function input:connected() return connection.Connected end
    return input
end
local movement = { UserInputType = 'MouseMovement', Position = { X = 20, Y = 30 } }
for _, state in { 'End', 'Cancel' } do
    local input = press()
    local moves, endings = 0, 0
    overlay.drag(input, function() moves += 1 end, function() endings += 1 end)
    local active = capture
    active.InputChanged(movement)
    assert(moves == 1)
    -- Reproduce release without any InputEnded being delivered to the new overlay.
    input:setState(state)
    assert(active.destroyed and not input:connected())
    assert(endings == 1)
    active.InputChanged(movement)
    active.InputEnded({ UserInputType = 'MouseButton1' })
    active.MouseLeave()
    assert(moves == 1 and endings == 1, 'Release must stop movement and finish once')
end
local input = press('End')
overlay.drag(input, function() error('Already released') end)
assert(capture.destroyed and not input:connected(), 'An already released press must close immediately')
input = press()
overlay.drag(input, function() error('Disposed drag') end)
local disposed = capture
scopes[#scopes]()
assert(not input:connected())
disposed.InputChanged(movement)
print('Drag release checks passed')

-- Popups follow the control that opened them, and close once it scrolls out of view.
local scroller = { AbsolutePosition = point(0, 100), AbsoluteSize = point(200, 300) }
local listeners = {}
local target = {
    AbsolutePosition = point(10, 150), AbsoluteSize = point(100, 28), Parent = scroller,
    FindFirstAncestorWhichIsA = function(_, class) return if class == 'ScrollingFrame' then scroller else nil end,
    GetPropertyChangedSignal = function(_, property)
        return { Connect = function(_, callback)
            listeners[property] = callback
            return { Disconnect = function() listeners[property] = nil end }
        end }
    end,
    AncestryChanged = { Connect = function(_, callback)
        listeners.Ancestry = callback
        return { Disconnect = function() listeners.Ancestry = nil end }
    end },
}
local closed = 0
local anchor
local release = vide.root(function()
    anchor = overlay.anchor(target, function() closed += 1 end)
end)
assert(anchor().Y == 150)
target.AbsolutePosition = point(10, 120)
listeners.AbsolutePosition()
assert(anchor().Y == 120 and closed == 0, 'Popups must follow their control while scrolling')
target.AbsolutePosition = point(10, 60)
listeners.AbsolutePosition()
assert(closed == 1, 'Popups must close once their control scrolls out of view')
target.Parent = nil
listeners.Ancestry()
assert(closed == 2, 'Popups must close when their control is removed')
release()
assert(listeners.AbsolutePosition == nil, 'Closing a popup must stop following its control')
print('Popup anchoring checks passed')
