#!/usr/bin/env luajit
local ffi = require 'ffi'
local gl = require 'ffi.OpenGL'
local vec3sz = require 'ffi.vec.vec3sz'
local vec3d = require 'ffi.vec.vec3d'
local class = require 'ext.class'
local table = require 'ext.table'
local range = require 'ext.range'
local file = require 'ext.file'
local GLApp = require 'glapp'
local GLProgram = require 'gl.program'
local Orbit = require 'glapp.orbit'
local View = require 'glapp.view'
local template = require 'template'
local bit = require 'bit'
local CLEnv = require 'cl.obj.env'
local clnumber = require 'cl.obj.number'

local n = 8

local xmin = vec3d(-1,-1,-1) * 1.5
local xmax = vec3d(1,1,1) * 1.5

local vectorFieldShader


local App = class(Orbit(View.apply(GLApp)))

App.viewDist = 5

function App:initGL()
	local env = CLEnv{size={n,n,n}}
	self.env = env


	local typeCode = [[
typedef union {
	real s[3];
	struct { real x, y, z; };
} real3;
]]

	ffi.cdef(typeCode)


	env.code = table{
		env.code,
		typeCode,
		[[
#define _real3(x,y,z)	(real3){.s={x,y,z}}
inline real3 real3_add(real3 a, real3 b) { return _real3(a.x + b.x, a.y + b.y, a.z + b.z); }
inline real3 real3_scale(real3 a, real s) { return _real3(a.x * s, a.y * s, a.z * s); }
]],
	}:concat'\n'

		
	local code = file['vectorfield.shader']
	
	vectorFieldShader = GLProgram{
		vertexCode = template(code, {
			vertexShader = true,
			dim = env.base.dim,
			clnumber = clnumber,
		}),
		fragmentCode = template(code, {
			fragmentShader = true,
			dim = env.base.dim,
			clnumber = clnumber,
		}),
		uniforms = {
			tex = 0,
		},
	}
	
	-- allocate cl buffer
	self.fieldBuf = env:buffer{name='field', type='real3'}

	-- initialize buffer
	env:kernel{
		name = 'init',
		argsOut = {self.fieldBuf},
		body = template([[
	real3 xmin = _real3(<?=clnumber(xmin.x)?>, <?=clnumber(xmin.y)?>, <?=clnumber(xmin.z)?>);	
	real3 xmax = _real3(<?=clnumber(xmax.x)?>, <?=clnumber(xmax.y)?>, <?=clnumber(xmax.z)?>);	
	
	real3 x = _real3(
		((real)i.x + .5) / (real)size.x * (xmax.x - xmin.x) + xmin.x,
		((real)i.y + .5) / (real)size.y * (xmax.y - xmin.y) + xmin.y,
		((real)i.z + .5) / (real)size.z * (xmax.z - xmin.z) + xmin.z);
	real3 w1 = _real3(
		x.x * x.z, 
		x.y * x.z, 
		1. - 2. * (x.x * x.x + x.y * x.y) - x.z * x.z);
	real3 w2 = _real3(-x.y, x.x, 0);
	field[index] = real3_add(real3_scale(w1, 1.5), w2);
]], {
	xmin = xmin,
	xmax = xmax,
	clnumber = clnumber,
}),
	}(self.fieldBuf)

	local CLGLTexXFer = require 'gltex'
	self.xfer = CLGLTexXFer{
		env = env,
		buffer = self.fieldBuf,
		type = self.env.real,
		channels = 3,
	}

	self.xfer:update()
end

-- [[
local geom = gl.GL_LINES
local vtxs = table{
	{-.5, 0, 0},
	{.5, 0, 0},
	{.2, .3, 0},
	{.5, 0, 0},
	{.2, -.3, 0},
	{.5, 0, 0},
}:map(function(t) return vec3d(table.unpack(t)) * .3 end)
local tris = range(#vtxs)
--]]
--[[
local geom = gl.GL_LINES
local vtxs = {
	{-.5, 0, 0},
	{.5, 0, 0},
}
local tris = range(#vtxs)
--]]
--[[
local geom = gl.GL_TRIANGLES
local res = 10
local vtxs = table{vec3d(.5 * .5, 0, 0)}:append(range(res):map(function(i)
	local theta = (i-.5)/res * 2 * math.pi
	return vec3d(-.5, .5 * math.cos(theta), .5 * math.sin(theta)) * .2
end)):append{vec3d(-.5, 0, 0) * .2}
local tris = table()
for i=1,res do
	tris:append{1, i+1, i%res+2}
	tris:append{res+2, i%res+2, i+1}
end
--]]
local normals 
if geom == gl.GL_TRIANGLES then
	normals = vtxs:map(function() return vec3d(0,0,0) end)
	for j=1,#tris,3 do
		local a, b, c = vtxs[tris[j]], vtxs[tris[j+1]], vtxs[tris[j+2]]
		local n = (b - a):cross(c - a):normalize()
		for k=0,2 do
			normals[tris[j+k]] = normals[tris[j+k]] + n
		end
	end
	for i=1,#normals do normals[i] = normals[i]:normalize() end
end

function App:update()
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))

	local env = self.env

	gl.glDisable(gl.GL_CULL_FACE)
	gl.glEnable(gl.GL_DEPTH_TEST)
	--gl.glEnable(gl.GL_BLEND)
	--gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE)
	
	local ar = self.width / self.height
	self.view:setup(ar)

	vectorFieldShader:use()

	self.xfer.tex:bind(0)
	
	gl.glUniform3f(vectorFieldShader.uniforms.xmin.loc, xmin:unpack())
	gl.glUniform3f(vectorFieldShader.uniforms.xmax.loc, xmax:unpack())

	gl.glBegin(geom)
	for k=0,tonumber(env.base.size.z-1) do
		for j=0,tonumber(env.base.size.y-1) do
			for i=0,tonumber(env.base.size.x-1) do
				local x = (i + .5) / tonumber(env.base.size.x)
				local y = (j + .5) / tonumber(env.base.size.y)
				local z = (k + .5) / tonumber(env.base.size.z)
				gl.glTexCoord3f(x, y, z)	
				for _,t in ipairs(tris) do
					if normals then gl.glNormal3f(normals[t]:unpack()) end
					gl.glVertex3f(vtxs[t]:unpack())
				end
			end
		end
	end
	gl.glEnd()
			
	self.xfer.tex:unbind(0)
	vectorFieldShader:useNone()
	
	gl.glDisable(gl.GL_BLEND)
	gl.glEnable(gl.GL_DEPTH_TEST)

end

App():run()
