varying vec4 color;
//varying vec3 normal;

<? 
if vertexShader then 
?>

uniform vec3 xmin, xmax;
uniform float scale;

<? if dim < 3 then ?>
uniform sampler2D tex;
<? else ?>
uniform sampler3D tex;
<? end ?>

uniform float valueMin, valueMax;
uniform sampler1D gradientTex;

void main() {
<? if dim < 3 then ?> 
	
	vec3 dir = texture2D(tex, gl_MultiTexCoord0.xy).rgb;
	float value = length(dir);
	dir /= value;

	vec3 ty = vec3(-dir.y, dir.x, 0.);
	vec3 tz = vec3(0., 0., 1.);

<? else ?>
	
	vec3 dir = texture3D(tex, gl_MultiTexCoord0.xyz).rgb;
	float value = length(dir);
	dir /= value;
	
	vec3 vx = vec3(0., -dir.z, dir.y);
	vec3 vy = vec3(dir.z, 0., -dir.x);
	vec3 vz = vec3(-dir.y, dir.x, 0.);
	float lxsq = dot(vx,vx);
	float lysq = dot(vy,vy);
	float lzsq = dot(vz,vz);
	vec3 ty, tz;
	if (lxsq > lysq) {		//x > y
		if (lxsq > lzsq) {	//x > z, x > y
			ty = vx;
		} else {			//z > x > y
			ty = vz;
		}
	} else {				//y >= x
		if (lysq > lzsq) {	//y >= x, y > z
			ty = vy;
		} else {			// z > y >= x
			ty = vz;
		}
	}
	tz = normalize(cross(dir, ty));

<? end ?>

	const float alpha = 1.;
	value = (value - valueMin) / (valueMax - valueMin);
	color = texture1D(gradientTex, value); 

	vec3 offset = gl_Vertex.xyz * scale * value;
	vec3 v = gl_MultiTexCoord0.xyz * (xmax - xmin) + xmin + (offset.x * dir + offset.y * ty + offset.z * tz);
	gl_Position = gl_ProjectionMatrix * gl_ModelViewMatrix * vec4(v, 1.);

	//normal = gl_NormalMatrix * gl_Normal;
}

<?
end
if fragmentShader then
?>

void main() {
	gl_FragColor = color;
	
	//vec3 n = normalize(normal);
	//gl_FragColor *= max(.1, -n.z);
}

<?
end
?>
