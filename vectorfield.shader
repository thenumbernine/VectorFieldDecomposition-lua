varying vec4 color;

<? 
if vertexShader then 
?>

uniform vec3 xmin, xmax;

<? if dim < 3 then ?>
uniform sampler2D tex;
<? else ?>
uniform sampler3D tex;
<? end ?>

void main() {
<? if dim < 3 then ?> 
	
	vec3 dir = texture2D(tex, gl_MultiTexCoord0.xy).rgb;
	float value = length(dir);
	dir /= value;

	vec3 tv = vec3(-dir.y, dir.x, 0.);

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
	vec3 tv;
	if (lxsq > lysq) {		//x > y
		if (lxsq > lzsq) {	//x > z, x > y
			tv = vx;
		} else {			//z > x > y
			tv = vz;
		}
	} else {				//y >= x
		if (lysq > lzsq) {	//y >= x, y > z
			tv = vy;
		} else {			// z > y >= x
			tv = vz;
		}
	}

<? end ?>

	color = vec4(1.,0.,0.,1.);

	vec2 offset = gl_Vertex.xy;
	vec3 v = gl_MultiTexCoord0.xyz * (xmax - xmin) + xmin + (offset.x * dir + offset.y * tv);
	gl_Position = gl_ProjectionMatrix * gl_ModelViewMatrix * vec4(v, 1.);
}

<?
end
if fragmentShader then
?>

void main() {
	gl_FragColor = color;
}

<?
end
?>
