local C = terralib.includec("math.h")

local function newclass(name)
    local mt = { __name = name, variants = terralib.newlist() }
    mt.__index = mt
    function mt:is(obj)
        local omt = getmetatable(obj)
        while omt ~= nil do
            if self == omt then return true end
            omt = omt.__parent
        end
        return false
    end
    function mt:new(obj)
        obj = obj or {}
        setmetatable(obj,self)
        return obj
    end
    function mt:Variant(name)
        local vt = { kind = name, __parent = self }
        for k,v in pairs(self) do
            vt[k] = v
        end
        self.variants:insert(vt)
        vt.__index = vt
        return vt
    end
    setmetatable(mt, { __newindex = function(self,idx,v)
        rawset(self,idx,v)
        for i,j in ipairs(self.variants) do
            rawset(j,idx,v)
        end
    end })
 
    return mt
end

local Op = newclass("Op") -- a primitive operator like + or sin

local Exp = newclass("Exp") -- an expression involving primitives
local Var = Exp:Variant("Var") -- a variable
local Apply = Exp:Variant("Apply") -- an application
local Const = Exp:Variant("Const") -- a constant, C

function Var:N() return self.p end
function Const:N() return 0 end
function Apply:N() return self.nvars end

local empty = terralib.newlist {}
function Exp:children() return empty end
function Apply:children() return self.args end 


function Var:cost() return 1 end
function Const:cost() return 1 end
function Apply:cost() 
    local c = 1
    for i,a in ipairs(self.args) do
        c = c + a:cost()
    end
    return c
end

function Const:__tostring() return tostring(self.v) end

local applyid = 0
local function newapply(op,args)
    local nvars = 0
    assert(not op.nparams or #args == op.nparams)
    for i,a in ipairs(args) do
        nvars = math.max(nvars,a:N())
    end
    applyid = applyid + 1
    return Apply:new { op = op, args = args, nvars = nvars, id = applyid - 1 }
end

local getconst = terralib.memoize(function(n) return Const:new { v = n } end)
local function toexp(n)
    return Exp:is(n) and n or tonumber(n) and getconst(n)
end

local zero,one,negone = toexp(0),toexp(1),toexp(-1)
local function allconst(args)
    for i,a in ipairs(args) do
        if not Const:is(a) then return false end
    end
    return true
end

-- define a complete ordering of all nodes
-- any commutative op should reorder its nodes in this order
function Const:order()
    return 2,self.v
end

function Apply:order()
    return 1,self.id
end

function Var:order()
    return 0,self.p
end

local function lessthan(a,b) 
    local ah,al = a:order()
    local bh,bl = b:order()
    if ah < bh then return true
    elseif bh < ah then return false
    else return al < bl end
end

local commutes = { add = true, mul = true }
local assoc = { add = true, mul = true }
local function factors(e)
    if Apply:is(e) and e.op.name == "mul" then
        return e.args[1],e.args[2]
    end
    return e,one
end
local function simplify(op,args)
    local x,y = unpack(args)
    
    if allconst(args) and op:getimpl() then
        return toexp(op:getimpl()(unpack(args:map("v"))))
    elseif commutes[op.name] and lessthan(y,x) then return op(y,x)
    elseif assoc[op.name] and Apply:is(x) and x.op.name == op.name then
        return op(x.args[1],op(x.args[2],y))
    elseif op.name == "mul" then
        if y == one then return x
        elseif y == zero then return zero
        elseif y == negone then return -x
        end
    elseif op.name == "add" then
        if y == zero then return x 
        end
        local x0,x1 = factors(x)
        local y0,y1 = factors(y)
        if x0 == y0 then return x0*(x1 + y1)
        elseif x1 == y1 then return (x0 + y0)*x1
        end
    elseif op.name == "sub" then
        if x == y then return zero
        elseif y == zero then return x
        elseif x == zero then return -y 
        end
    elseif op.name == "div" then
        if y == one then return x
        elseif y == negone then return -x
        elseif x == y then return one 
        end
    end
    return newapply(op,args)
end


local getapply = terralib.memoize(function(op,...)
    local args = terralib.newlist {...}
    return simplify(op,args)
end)


local function toexps(...)
    local es = terralib.newlist {...}
    for i,e in ipairs(es) do
        es[i] = assert(toexp(e))
    end
    return es
end
    

-- generates variable names
local v = setmetatable({},{__index = function(self,idx)
    local r = Var:new { p = assert(tonumber(idx)) }
    self[idx] = r
    return r
end})

local x,y,z = v[1],v[2],v[3]

local ad = {}
setmetatable(ad, { __index = function(self,idx)
    local name = assert(type(idx) == "string" and idx)
    local op = Op:new { name = name }
    rawset(self,idx,op)
    return op
end })

function Op:__call(...)
    local args = toexps(...)
    return getapply(self,unpack(args))
end
function Op:define(fn,...)
    self.nparams = debug.getinfo(fn,"u").nparams
    self.generator = fn
    self.derivs = toexps(...)
    for i,d in ipairs(self.derivs) do
        assert(d:N() <= self.nparams)
    end
    return self
end
function Op:getimpl()
    if self.impl then return self.impl end
    if not self.generator then return nil
    else
        local s = terralib.newlist()
        for i = 1,self.nparams do
            s:insert(symbol(float))
        end
        terra self.impl([s]) return [self.generator(unpack(s))] end
        return self.impl
    end
end

function Op:__tostring() return self.name end

local mo = {"add","sub","mul","div"}
for i,o in ipairs(mo) do
    Exp["__"..o] = function(a,b) return (ad[o])(a,b) end
end
Exp.__unm = function(a) return ad.unm(a) end

function Var:rename(vars)
    assert(self.p <= #vars)
    return vars[self.p]
end
function Const:rename(vars) return self end
function Apply:rename(vars)
    assert(self:N() <= #vars) 
    return self.op(unpack(self.args:map("rename",vars)))
end

local function countuses(es)
    local uses = {}
    local function count(e)
        uses[e] = (uses[e] or 0) + 1
        if uses[e] == 1 and e.kind == "Apply" then
            for i,a in ipairs(e.args) do count(a) end
        end
    end
    for i,a in ipairs(es) do count(a) end
    for k,v in pairs(uses) do
       uses[k] = v > 1 or nil
    end
    return uses
end    


local infix = { add = {"+",1}, sub = {"-",1}, mul = {"*",2}, div = {"/",2} }


local function expstostring(es)
    local n = 0
    local tbl = terralib.newlist()
    local manyuses = countuses(es)
    local emitted = {}
    local function prec(e)
        if e.kind ~= "Apply" or e.op.name == "unm" or not infix[e.op.name] or manyuses[e] then return 3
        else return infix[e.op.name][2] end
    end
    local emit
    local function emitprec(e,p)
        return (prec(e) < p and "(%s)" or "%s"):format(emit(e))
    end
    local function emitapp(e)
        if e.op.name == "unm" then
            return ("-%s"):format(emitprec(e.args[1],3))
        elseif infix[e.op.name] then
            local o,p = unpack(infix[e.op.name])
            return ("%s %s %s"):format(emitprec(e.args[1],p),o,emitprec(e.args[2],p+1))
        else
            return ("%s(%s)"):format(tostring(e.op),e.args:map(emit):concat(","))
        end
    end
    function emit(e)
        if "Var" == e.kind then
            return ("v%d"):format(e.p)
        elseif "Const" == e.kind then
            return tostring(e.v)
        elseif "Apply" == e.kind then
            if emitted[e] then return emitted[e] end
            local exp = emitapp(e)
            if manyuses[e] then
                local r = ("r%d"):format(n)
                n = n + 1
                emitted[e] = r
                tbl:insert(("  %s = %s\n"):format(r,exp))            
                return r
            else
                return exp
            end
            
        end
    end
    local r = es:map(emit)
    r = r:concat(",")
    if #tbl == 0 then return r end
    return ("let\n%sin\n  %s\nend\n"):format(tbl:concat(),r)
end

function Exp:__tostring()
    return expstostring(terralib.newlist{self})
end

function Exp:d(v)
    assert(Var:is(v))
    self.derivs = self.derivs or {}
    local r = self.derivs[v]
    if r then return r end
    r = self:calcd(v)
    self.derivs[v] = r
    return r
end
    
function Var:calcd(v)
   return self == v and toexp(1) or toexp(0)
end
function Const:calcd(v)
    return toexp(0)
end

ad.add:define(function(x,y) return `x + y end,1,1)
ad.sub:define(function(x,y) return `x - y end,1,-1)
ad.mul:define(function(x,y) return `x * y end,y,x)
ad.div:define(function(x,y) return `x / y end,1/y,-x/(y*y))
ad.unm:define(function(x) return `-x end, 1)
ad.acos:define(function(x) return `C.acos(x) end, -1.0/ad.sqrt(1.0 - x*x))
ad.acosh:define(function(x) return `C.acosh(x) end, 1.0/ad.sqrt(x*x - 1.0))
ad.asin:define(function(x) return `C.asin(x) end, 1.0/ad.sqrt(1.0 - x*x))
ad.asinh:define(function(x) return `C.asinh(x) end, 1.0/ad.sqrt(x*x + 1.0))
ad.atan:define(function(x) return `C.atan(x) end, 1.0/(x*x + 1.0))
ad.atan2:define(function(x,y) return `C.atan2(x*x+y*y,y) end, y/(x*x+y*y),x/(x*x+y*y))
ad.cos:define(function(x) return `C.cos(x) end, -ad.sin(x))
ad.cosh:define(function(x) return `C.cosh(x) end, ad.sinh(x))
ad.exp:define(function(x) return `C.exp(x) end, ad.exp(x))
ad.log:define(function(x) return `C.log(x) end, 1.0/x)
ad.log10:define(function(x) return `C.log10(x) end, 1.0/(ad.log(10.0)*x))
ad.pow:define(function(x,y) return `C.pow(x,y) end, y*ad.pow(x,y)/x,ad.log(x)*ad.pow(x,y)) 
ad.sin:define(function(x) return `C.sin(x) end, ad.cos(x))
ad.sinh:define(function(x) return `C.sinh(a) end, ad.cosh(x))
ad.sqrt:define(function(x) return `C.sqrt(x) end, 1.0/(2.0*ad.sqrt(x)))
ad.tan:define(function(x) return `C.tan(x) end, 1.0 + ad.tan(x)*ad.tan(x))
ad.tanh:define(function(x) return `C.tanh(a) end, 1.0/(ad.cosh(x)*ad.cosh(x)))


local function dominators(startnode,succ)
    -- calculate post order traversal order
    local visited = {}
    local nodes = terralib.newlist()
    local nodeindex = {}
    local function visit(n)
        if visited[n] then return end
        visited[n] = true
        for i,c in ipairs(succ(n)) do
            visit(c)
        end
        nodes:insert(n)
        nodeindex[n] = #nodes
    end
    visit(startnode)
    
    -- calculate predecessors (postorderid -> list(postorderid))
    local pred = {}
    
    for i,n in ipairs(nodes) do
        for j,c in ipairs(succ(n)) do
            local ci = nodeindex[c]
            pred[ci] = pred[ci] or terralib.newlist()
            pred[ci]:insert(i)
        end
    end
    
    assert(nodeindex[startnode] == #nodes)
    -- calculate immediate dominators
    local doms = terralib.newlist{}
    
    doms[#nodes] = #nodes
    
    local function intersect(finger1,finger2)
        while finger1 ~= finger2 do
            while finger1 < finger2 do
                finger1 = assert(doms[finger1])
            end
            while finger2 < finger1 do
                finger2 = assert(doms[finger2])
            end
        end
        return finger1
    end
    
    local changed = true
    while changed do
        changed = false
        --[[
        for i = #nodes,1,-1 do
            print(i,doms[i])
        end
        print()]]
        for b = #nodes-1,1,-1 do
            local bpred = pred[b]
            local newidom
            for i,p in ipairs(bpred) do
                if doms[p] then
                    newidom = newidom and intersect(p,newidom) or p
                end
            end
            if doms[b] ~= newidom then
                doms[b] = newidom
                changed = true
            end
        end
    end
    
    local r = {}
    for i,n in ipairs(nodes) do
        r[n] = nodes[doms[i]]
    end
    return r
end

function Exp:partials()
    return empty
end
function Apply:partials()
    self.partiallist = self.partiallist or self.op.derivs:map("rename",self.args)
    return self.partiallist
end

if false then
    function Apply:calcd(X)
        -- extract derivative graph
        assert(Var:is(X))
        local succ = {}
        local pred = {}
        local function insertv(g,k,v)
            g[k] = g[k] or terralib.newlist()
            g[k]:insert(v)
        end
        local function deletev(g,k,v)
            local es = g[k]
            for i,e in ipairs(es) do
                if e == v then
                    es:remove(i)
                    return
                end
            end
            error("not found")
        end
        local function insert(e)
            insertv(succ,e.from,e)
            insertv(pred,e.to,e)
        end
        local function remove(e)
            removev(succ,e.from,e)
            removev(pred,e.to,e)
        end
       
        local ingraph = {}
        local function visit(n)
            if ingraph[n] ~= nil then return ingraph[n] end
            local partials = n:partials()
            local include = n == X
            for i,c in ipairs(n:children()) do
                if visit(c) then    
                    include = true
                    insert { from = c, to = n, d = partials[i] }
                end
            end
            ingraph[n] = include
            return include
        end
        visit(self)
    
        local function simple(x)
            if not pred[x] then return terralib.newlist{ toexp(1) } end
            local r = terralib.newlist()
            for i,p in ipairs(pred[x]) do
                local s = simple(p.from)
                r:insertall(s:map(function(v) return v*p.d end))
            end
            return r
        end
        local r
        local factors = simple(self)
        for i,f in ipairs(factors) do
            r = (r and r + f) or f
        end
        return r or toexp(0)
    end
else
    function Apply:calcd(v)
    local dargsdv = self.args:map("d",v)
    local dfdargs = self:partials()
    local r
    for i = 1,#self.args do
        local e = dargsdv[i]*dfdargs[i]
        r = (not r and e) or (r + e)
    end
    return r
end

end
if false then
    local n1,n2,n3 = {name = "n1"},{name = "n2"},{name = "n3"}
    n1[1] = n2
    n2[1] = n1
    n2[2] = n3
    n3[1] = n2

    local n4 = { n3, n2 , name = "n4" }
    local n5 = { n1, name = "n5"}
    local n6 = {n4,n5, name = "n6"}

    local d = dominators(n6,function(x) return x end)

    for k,v in pairs(d) do
        print(k.name," <- ",v.name)
    end
end


--[[
print(expstostring(ad.atan2.derivs))



assert(y == y)
assert(ad.cos == ad.cos)
local r = ad.sin(x) + ad.cos(y) + ad.cos(y)
print(r)
print(expstostring( terralib.newlist { r, r + 1} ))

print(x*-(-y+1)/4)

print(r:rename({x+y,x+y}))]]


local e = 2*x*x*x*3 -- - y*x

print((ad.sin(x)*ad.sin(x)):d(x))

print(e:d(x)*3+(4*x)*x)
