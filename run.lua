#!/usr/bin/env luajit
local bit = require 'bit'
local ffi = require 'ffi'
local gl = require 'ffi.OpenGL'
local ig = require 'imgui'
local vec3sz = require 'vec-ffi.vec3sz'
local vec3d = require 'vec-ffi.vec3d'
local class = require 'ext.class'
local table = require 'ext.table'
local range = require 'ext.range'
local file = require 'ext.file'
local gnuplot = require 'gnuplot'
local template = require 'template'
local GLProgram = require 'gl.program'
local GLGradientTex = require 'gl.gradienttex'
local CLEnv = require 'cl.obj.env'
local clnumber = require 'cl.obj.number'

local n = 10

local xmin = vec3d(-1,-1,-1) * 1.5
local xmax = vec3d(1,1,1) * 1.5

local vectorFieldShader

local vectorFieldScale = 1

local App = class(require 'glapp.orbit'(require 'imguiapp'))

App.viewDist = 5

function App:initGL()
	App.super.initGL(self)
	
	local env = CLEnv{size={n,n,n}}
	self.env = env


	local typeCode = [[
typedef union real3 {
	real s[3];
	struct { real s0, s1, s2; }; 
	struct { real x, y, z; };
} real3;
]]

	ffi.cdef(typeCode)

	env.code = table{
		env.code,
		typeCode,
		template([[
#define _real3(x,y,z)	(real3){.s={x,y,z}}
inline real3 real3_add(real3 a, real3 b) { return _real3(a.x + b.x, a.y + b.y, a.z + b.z); }
inline real3 real3_sub(real3 a, real3 b) { return _real3(a.x - b.x, a.y - b.y, a.z - b.z); }
inline real3 real3_scale(real3 a, real s) { return _real3(a.x * s, a.y * s, a.z * s); }
inline real real3_dot(real3 a, real3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline real real3_lenSq(real3 a) { return real3_dot(a, a); } 
inline real real3_length(real3 a) { return sqrt(real3_lenSq(a)); } 

constant const real3 dx = (real3){.s={<?=clnumber(dx.x)?>, <?=clnumber(dx.y)?>, <?=clnumber(dx.z)?>}};
]], {
	clnumber = clnumber,
	dx = (xmax - xmin) / vec3d(self.env.base.size:unpack()),
}),
	}:concat'\n'


	local gradTexWidth = 1024
	self.gradientTex = GLGradientTex(gradTexWidth, {
	-- [[ white, rainbow, black
		{0,0,0,.5},	-- black ... ?
		{0,0,1,1},	-- blue
		{0,1,1,1},	-- cyan
		{0,1,0,1},	-- green
		{1,1,0,1},	-- yellow
		{1,.5,0,1},	-- orange
		{1,0,0,1},	-- red
		{1,1,1,1},	-- white
	--]]
	--[[ stripes 
		range(32):map(function(i)
			return ({
				{0,0,0,0},
				{1,1,1,1},
			})[i%2+1]
		end):unpack()
	--]]
	}, false)
	-- don't wrap the colors, but do use GL_REPEAT
	self.gradientTex:setWrap{s = gl.GL_REPEAT}

		
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
			gradientTex = 1,
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
	
#if 0	//this was somewhere in the paper.  it looks very simiar to the z axis of the basis of a quaternion
	real3 w1 = _real3(
		x.x * x.z, 
		x.y * x.z, 
		1. - 2. * (x.x * x.x + x.y * x.y) - x.z * x.z);
	real3 w2 = _real3(-x.y, x.x, 0);
	field[index] = w2;//real3_add(real3_scale(w1, 1.5), w2);
#endif
#if 0	//add a x exp(-x^2) to the whole thing
	real3 w1 = _real3(
		x.x * x.z, 
		x.y * x.z, 
		1. - 2. * (x.x * x.x + x.y * x.y) - x.z * x.z);
	real3 w2 = _real3(-x.y, x.x, 0);
	real rSq = real3_lenSq(x);
	field[index] = real3_scale(real3_add(real3_scale(w1, 1.5), w2), 1. / (rSq + 1.));
#endif
#if 1	//divergence, curl-free
	field[index] = x;
#endif
]], {
	xmin = xmin,
	xmax = xmax,
	clnumber = clnumber,
}),
	}()

	-- divergence of the field
	self.divBuf = env:buffer{name='div', type='real'}
	env:kernel{
		argsOut = {self.divBuf},
		argsIn = {self.fieldBuf},
		body = template([[
	div[index] = 0.;
	<? for i=0,dim-1 do ?>{
		int4 iR = i; iR.s<?=i?> = min(i.s<?=i?> + 1, size.s<?=i?> - 1);
		int4 iL = i; iL.s<?=i?> = max(i.s<?=i?> - 1, 0);
		div[index] += (
			field[indexForInt4(iR)].s<?=i?> 
			- field[indexForInt4(iL)].s<?=i?>
		) / (2. * dx.s<?=i?>);
	}<? end ?>
]], {dim=self.env.base.dim}),
	}()

	-- inverse laplacian
	self.potentialBuf = env:buffer{name='potential', type='real'}

	-- initial guess
	self.potentialBuf:copyFrom(self.divBuf)
	
	local lap = env:kernel{
		argsOut = {{name='lap', type='real', obj=true}},
		argsIn = {{name='div', type='real', obj=true}},
		body = template([[
	lap[index] = -(2. * dim) * div[index];
	<? for i=0,env.base.dim-1 do ?>{
		int4 iR = i;
		iR.s<?=i?> = min(i.s<?=i?> + 1, size.s<?=i?> - 1);
		int4 iL = i;
		iL.s<?=i?> = max(i.s<?=i?> - 1, 0);
		lap[index] += (div[indexForInt4(iR)] - div[indexForInt4(iL)]) / (dx.s<?=i?> * dx.s<?=i?>);
	}<? end ?>
]], {env=env}),
	}
	
	-- lap phi = div
	local residuals = table()
	require 'solver.cl.gmres'{
		env = env,
		A = lap,
		x = self.potentialBuf,
		b = self.divBuf,
		errorCallback = function(residual, iter)
			print(iter, residual)
			residuals:insert(residual)
		end,
		epsilon = 1e-12,
		maxiter = env.base.volume * 10,
		restart = 10,
	}()

	gnuplot{
		output = 'inverse laplace residual.png',
		style = 'data lines',
		log = 'y',
		data = {residuals},
		{using='0:1', title='residuals'},
	}

	-- gradient of the inv lap = curl-free
	self.curlFreeBuf = env:buffer{name='curlFree', type='real3'}
	env:kernel{
		argsOut = {self.curlFreeBuf},
		argsIn = {self.potentialBuf},
		body = template([[
	<? for i=0,env.base.dim-1 do ?>{
		int4 iR = i;
		iR.s<?=i?> = min(i.s<?=i?> + 1, size.s<?=i?> - 1);
		int4 iL = i;
		iL.s<?=i?> = max(i.s<?=i?> - 1, 0);
		curlFree[index].s<?=i?> = (potential[indexForInt4(iR)] - potential[indexForInt4(iL)]) / (2. * dx.s<?=i?>);
	}<? end ?>
]], {env=env}),
	}()

	self.divFreeBuf = env:buffer{name='divFree', type='real3'}
	env:kernel{
		argsOut = {self.divFreeBuf},
		argsIn = {self.fieldBuf, self.curlFreeBuf},
		body = [[
	divFree[index] = real3_sub(field[index], curlFree[index]);
]],
	}()

	--[[ now try the algorithm that the paper suggests ...
	1) start with random phi = lambda, mu, phi
	2) minimize 1/4 |ds|^2 + 1/h^2 (eta - eta_0)^2
	...where s = pi(phi)
	eta = phi* alpha
	alpha = h(dq, iq)
	--]]	

	self.displayVars = table{
		{name='fieldBuf'},
		{name='divBuf'},
		{name='potentialBuf'},
		{name='curlFreeBuf'},
		{name='divFreeBuf'},
	}

	-- TODO instead of doing CL copies, how about an option for kernels to write out?
	-- that's the faster method
	local CLGLTexXFer = require 'gltex'
	self.xfer = CLGLTexXFer{env = env}
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

	for _,var in ipairs(self.displayVars) do
		if var.enabled then
			local buf = self[var.name]
			self.xfer:update(buf)

			local scalar = buf.type == 'real' or buf.type == self.env.real 

			vectorFieldShader:use()
			
			self.xfer.tex:bind(0)
			self.gradientTex:bind(1)
			
			gl.glUniform1f(vectorFieldShader.uniforms.valueMin.loc, 0)
			gl.glUniform1f(vectorFieldShader.uniforms.valueMax.loc, 1)
			gl.glUniform1f(vectorFieldShader.uniforms.scale.loc, vectorFieldScale)
			gl.glUniform3f(vectorFieldShader.uniforms.xmin.loc, xmin:unpack())
			gl.glUniform3f(vectorFieldShader.uniforms.xmax.loc, xmax:unpack())

			gl.glBegin(scalar and gl.GL_POINTS or geom)
			for k=0,tonumber(env.base.size.z-1) do
				for j=0,tonumber(env.base.size.y-1) do
					for i=0,tonumber(env.base.size.x-1) do
						local x = (i + .5) / tonumber(env.base.size.x)
						local y = (j + .5) / tonumber(env.base.size.y)
						local z = (k + .5) / tonumber(env.base.size.z)
						gl.glTexCoord3f(x, y, z)	
						if scalar then
							gl.glVertex3f(0,0,0)
						else
							for _,t in ipairs(tris) do
								if normals then gl.glNormal3f(normals[t]:unpack()) end
								gl.glVertex3f(vtxs[t]:unpack())
							end
						end
					end
				end
			end
			gl.glEnd()
			
			self.gradientTex:unbind(1)
			self.xfer.tex:unbind(0)
			vectorFieldShader:useNone()
		end
	end

	gl.glDisable(gl.GL_BLEND)
	gl.glEnable(gl.GL_DEPTH_TEST)

	App.super.update(self)
end

local bool = ffi.new'bool[1]'
local float = ffi.new'float[1]'
function App:updateGUI()
	float[0] = vectorFieldScale
	if ig.igInputFloat('scale', float) then
		vectorFieldScale = float[0]
	end

	for _,var in ipairs(self.displayVars) do
		bool[0] = not not var.enabled
		if ig.igCheckbox(var.name, bool) then
			var.enabled = bool[0]
		end
	end
end

return App():run()
