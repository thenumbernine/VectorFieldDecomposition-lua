#!/usr/bin/env luajit
local ffi = require 'ffi'
local gl = require 'ffi.OpenGL'
local vec3sz = require 'ffi.vec.vec3sz'
local vec3d = require 'ffi.vec.vec3d'
local class = require 'ext.class'
local table = require 'ext.table'
local file = require 'ext.file'
local GLApp = require 'glapp'
local GLProgram = require 'gl.program'
local GLTex2D = require 'gl.tex2d'
local GLTex3D = require 'gl.tex3d'
local Orbit = require 'glapp.orbit'
local View = require 'glapp.view'
local template = require 'template'
local bit = require 'bit'
local CLEnv = require 'cl.obj.env'
local clnumber = require 'cl.obj.number'

local n = 32

local xmin = vec3d(-1,-1,-1) * 1.5
local xmax = vec3d(1,1,1) * 1.5

local vectorFieldShader
local fieldTex


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
		body = [[
	real3 x = _real3(
		((real)i.x + .5) / (real)size.x,
		((real)i.y + .5) / (real)size.y,
		((real)i.z + .5) / (real)size.z);
	real3 w1 = _real3(
		x.x * x.z, 
		x.y * x.z, 
		1. - 2. * (x.x * x.x + x.y * x.y) - x.z * x.z);
	real3 w2 = _real3(-x.y, x.x, 0);
	field[index] = real3_add(real3_scale(w1, 1.5), w2);
]]
	}(self.fieldBuf)

	-- initialize upload-to-texture
	local _class = env.base.dim < 3 and GLTex2D or GLTex3D
	fieldTex = _class{
		width = tonumber(env.base.size.x),
		height = tonumber(env.base.size.y),
		depth = tonumber(env.base.size.z),
		internalFormat = gl.GL_RGBA32F,
		format = gl.GL_RGBA,
		type = gl.GL_FLOAT,
		minFilter = gl.GL_NEAREST,
		--magFilter = gl.GL_NEAREST,
		magFilter = gl.GL_LINEAR,
		wrap = {s=gl.GL_REPEAT, t=gl.GL_REPEAT, r=gl.GL_REPEAT},
	}

	-- TODO put this in cl.obj.buffer
	if env.useGLSharing then
		self.texCLMem = CLImageGL{context=env.ctx, tex=fieldTex, write=true}
	else
		self.bufferTexPtr = ffi.new(env.real..'[?]', env.base.volume * 3)
	end

	-- update the texture
	if env.useGLSharing then
		-- copy to GL using cl_*_gl_sharing
		gl.glFinish()
		env.cmds:enqueueAcquireGLObjects{objs={self.texCLMem}}

		copyFieldToTex()
		
		env.cmds:enqueueReleaseGLObjects{objs={self.texCLMem}}
		env.cmds:finish()
	else
		local ptr = self.bufferTexPtr
		local tex = fieldTex
		local channels = 3
		local format = gl.GL_RGB
		env.cmds:enqueueReadBuffer{buffer=self.fieldBuf.obj, block=true, size=ffi.sizeof(env.real) * env.base.volume * channels, ptr=ptr}
		local destPtr = ptr
		if env.real == 'double' then
			-- can this run in place?
			destPtr = ffi.cast('float*', ptr)
			for i=0,env.base.volume*channels-1 do
				destPtr[i] = ptr[i]
			end
		end
		tex:bind()
		if self.env.base.dim < 3 then
			gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, tex.width, tex.height, format, gl.GL_FLOAT, destPtr)
		else
			for z=0,tex.depth-1 do
				gl.glTexSubImage3D(gl.GL_TEXTURE_3D, 0, 0, 0, z, tex.width, tex.height, 1, format, gl.GL_FLOAT, destPtr + channels * tex.width * tex.height * z)
			end
		end
		tex:unbind()
	end
end

--[[
local arrow = {
	{-.5, 0.},
	{.5, 0.},
	{.2, .3},
	{.5, 0.},
	{.2, -.3},
	{.5, 0.},
}
--]]
local arrow = {
	{-.5, 0.},
	{.5, 0.},
}

function App:update()
	local env = self.env
	
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	
	local ar = self.width / self.height
	self.view:setup(ar)

	vectorFieldShader:use()

	fieldTex:bind(0)
	
	gl.glUniform3f(vectorFieldShader.uniforms.xmin.loc, xmin:unpack())
	gl.glUniform3f(vectorFieldShader.uniforms.xmax.loc, xmax:unpack())

	gl.glBegin(gl.GL_LINES)
	for k=0,tonumber(env.base.size.z-1) do
		for j=0,tonumber(env.base.size.y-1) do
			for i=0,tonumber(env.base.size.x-1) do
				local x = (i + .5) / tonumber(env.base.size.x)
				local y = (j + .5) / tonumber(env.base.size.y)
				local z = (k + .5) / tonumber(env.base.size.z)
				gl.glTexCoord3f(x, y, z)	
				for _,q in ipairs(arrow) do
					gl.glVertex2f(q[1], q[2])
				end
			end
		end
	end
	gl.glEnd()
			
	fieldTex:unbind(0)
	vectorFieldShader:useNone()

end

App():run()
