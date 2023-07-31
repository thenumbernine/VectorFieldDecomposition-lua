--[[
not sure what to name this class
it handles allocating and transferring to a gl texture
it uses gl sharing when available
--]]
local ffi = require 'ffi'
local gl = require 'gl'
local class = require 'ext.class'
local GLTex2D = require 'gl.tex2d'
local GLTex3D = require 'gl.tex3d'

local CLGLTexXFer = class()

--[[
args:
	env
	domain, defaults to env.base
	type
	channels
--]]
function CLGLTexXFer:init(args)
	self.env = assert(args.env, "expected env")
	self.domain = assert(self.domain or self.env.base, "expected domain or env to have been constructed with a domain")
	self.type = args.type or self.env.real
	self.channels = args.channels or 3

	-- initialize upload-to-texture
	local glTexClass = self.domain.dim < 3 and GLTex2D or GLTex3D
	self.tex = glTexClass{
		width = tonumber(self.domain.size.x),
		height = tonumber(self.domain.size.y),
		depth = tonumber(self.domain.size.z),
		internalFormat = gl.GL_RGBA32F,
		format = gl.GL_RGBA,
		type = gl.GL_FLOAT,
		minFilter = gl.GL_NEAREST,
		--magFilter = gl.GL_NEAREST,
		magFilter = gl.GL_LINEAR,
		wrap = {s=gl.GL_REPEAT, t=gl.GL_REPEAT, r=gl.GL_REPEAT},
	}

	-- TODO put this in cl.obj.buffer
	if self.env.useGLSharing then
		self.texCLMem = CLImageGL{context=self.env.ctx, tex=self.tex, write=true}
	else
		-- make sure this is at least as big as the cl read and gl write
		-- cl read is usually bigger
		self.bufferTexPtr = ffi.new(self.type..'[?]', self.domain.volume * self.channels)
	end
end

function CLGLTexXFer:update(buffer)
	-- update the texture
	if self.env.useGLSharing then
		-- copy to GL using cl_*_gl_sharing
		gl.glFinish()
		self.env.cmds:enqueueAcquireGLObjects{objs={self.texCLMem}}

		copyFieldToTex()
		
		self.env.cmds:enqueueReleaseGLObjects{objs={self.texCLMem}}
		self.env.cmds:finish()
	else
		local ptr = self.bufferTexPtr
		local tex = self.tex
		
		local channels = self.channels
		
		-- TODO this is going to depend on self.buffer.type
		-- ... so is whether to convert the buffer from double to float or not ...
		-- right now I'm only supporting 1 channel ...
		if buffer.type == 'real' or buffer.type == self.env.real then 
			channels = 1 
		elseif buffer.type == 'real3' then 
			channels = 3
		else
			error("couldn't deduce number of channels in CL buffer")
		end

		local format = assert(({
			[1] = gl.GL_RED,
			[3] = gl.GL_RGB,
		})[channels], "failed to find GL type for channels "..channels)
		
		self.env.cmds:enqueueReadBuffer{
			buffer = buffer.obj,
			block = true,
			size = ffi.sizeof(self.type) * self.domain.volume * channels,
			ptr = ptr,
		}
		local destPtr = ptr
		if self.type == 'double' then
			-- can this run in place?
			destPtr = ffi.cast('float*', ptr)
			for i=0,self.domain.volume*channels-1 do
				destPtr[i] = ptr[i]
			end
		end
		tex:bind()
		if self.domain.dim < 3 then
			gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, tex.width, tex.height, format, gl.GL_FLOAT, destPtr)
		else
			for z=0,tex.depth-1 do
				gl.glTexSubImage3D(gl.GL_TEXTURE_3D, 0, 0, 0, z, tex.width, tex.height, 1, format, gl.GL_FLOAT, destPtr + channels * tex.width * tex.height * z)
			end
		end
		tex:unbind()
	end
end

return CLGLTexXFer 
