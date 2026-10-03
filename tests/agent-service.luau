-- Exercise the actual background service without mounting the panel.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local threads, jobs, completed = {}, {}, {}
local serializations = 0
local function node(name, class, parent)
    local result = { Name = name, ClassName = class, Archivable = false, Parent = parent, children = {} }
    if parent then table.insert(parent.children, result) end
    function result:GetChildren() return self.children end
    function result:GetDescendants()
        local all = {}
        for _, child in self.children do
            table.insert(all, child)
            for _, descendant in child:GetDescendants() do table.insert(all, descendant) end
        end
        return all
    end
    function result:IsA(kind) return kind == self.ClassName or kind == "BasePart" and self.ClassName == "Part" end
    function result:IsDescendantOf(ancestor)
        local current = self.Parent
        while current do
            if current == ancestor then return true end
            current = current.Parent
        end
        return false
    end
    function result:FindFirstChildOfClass(kind)
        for _, child in self.children do if child.ClassName == kind then return child end end
        return nil
    end
    function result:Clone()
        assert(self.Archivable, "Snapshot must temporarily allow cloning")
        local function copy(original, owner)
            local clone = node(original.Name, original.ClassName, owner)
            clone.Archivable = original.Archivable
            clone.original = original
            for _, child in original.children do
                if child.Archivable then copy(child, clone) end
            end
            return clone
        end
        return copy(self, nil)
    end
    function result:Destroy() self.destroyed = true end
    return result
end
local game = node("Place", "DataModel")
game.PlaceId = 0
local workspace = node("Workspace", "Workspace", game)
local part = node("Crate", "Part", workspace)
node("Duplicate", "Part", workspace)
node("Duplicate", "Part", workspace)
local rig = node("Rig", "Model", workspace)
node("Humanoid", "Humanoid", rig)
local limb = node("Torso", "Part", rig)
node("Shirt", "Shirt", rig)
local dropped = false
local http = {
    GenerateGUID = function() return "session" end,
    JSONEncode = function(_, value) return serde.encode("json", value) end,
    JSONDecode = function(_, value) return serde.decode("json", value) end,
    RequestAsync = function(_, options)
        assert(options.Headers["X-Prism"] == "1")
        local body = serde.decode("json", options.Body)
        local response
        if options.Url:match("/sessions$") then response = {id = "session"}
        elseif options.Url:match("/poll$") then response = {job = table.remove(jobs, 1)}
        else
            table.insert(completed, body)
            -- Simulate a lost completion response, then acknowledge the same job.
            if body.id == "render" and not dropped then dropped = true; error("connection lost") end
            response = {status = "completed"}
        end
        return {Success = true, StatusCode = 200, Body = serde.encode("json", response)}
    end,
}
function game:GetService(name)
    assert(name == "HttpService", "Agent must not use Selection or UI services")
    return http
end
local modules = {
    ["./Version"] = "test",
    ["./Serializer"] = {serialize = function(copy)
        serializations += 1
        assert(copy ~= copy.original, "Serialize a snapshot, not the live instance")
        if copy.Name == "Torso" then
            assert(copy.Parent:FindFirstChildOfClass("Humanoid") and copy.Parent:FindFirstChildOfClass("Shirt"), "Limb snapshots preserve clothing context")
        end
        return {payload = {parts = {{}}}, warnings = {}}
    end},
}
local code = fs.readFile("src/AgentService.luau"):gsub("%f[%w]const%f[%W]", "local")
local service = luau.load(code, {environment = {
    game = game, require = function(path) return assert(modules[path], path) end,
    task = {spawn = function(fn) table.insert(threads, coroutine.create(fn)) end, wait = function() coroutine.yield() end},
}})()
local stop = service.create({GetSetting = function() return 49999 end})
local function step()
    for _, thread in threads do
        if coroutine.status(thread) ~= "dead" then
            local ok, message = coroutine.resume(thread)
            assert(ok, message)
        end
    end
end
jobs[1] = {id = "models", operation = "models", root = "Workspace", query = "Crate", limit = 100}
step(); step()
assert(completed[1].models[1].name == "Crate")
local target = completed[1].models[1].id
jobs[1] = {id = "render", operation = "serialize", items = {{target = target}, {path = {"Workspace", "Rig", "Torso"}}}}
step(); step(); step(); step()
assert(serializations == 2, "Lost responses must not reserialize a job")
assert(not part.Archivable and not limb.Archivable and not rig.Archivable, "Snapshot flags must be restored")
assert(completed[#completed].items[1].payload and completed[#completed].items[2].payload)
jobs[1] = {id = "errors", operation = "serialize", items = {{path = "Workspace.Duplicate"}, {path = "Workspace.Missing"}}}
step(); step()
assert(completed[#completed].items[1].error:find("Ambiguous", 1, true))
assert(completed[#completed].items[2].error:find("Missing", 1, true))
stop(); step()
print("Background agent discovery, snapshots, clothing context, retries and ambiguous path checks passed")
