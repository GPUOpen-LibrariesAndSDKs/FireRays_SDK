/**********************************************************************
Copyright �2015 Advanced Micro Devices, Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

?   Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
?   Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or
other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS
OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
********************************************************************/
#ifndef TEXTURE_CL
#define TEXTURE_CL

#include <../App/CL/utils.cl>

/// Supported formats
enum TextureFormat
{
    UNKNOWN,
    RGBA8,
    RGBA16,
    RGBA32
};

/// Texture description
typedef
    struct _Texture
    {
        // Width, height and depth
        int w;
        int h;
        int d;
        // Offset in texture data array
        int dataoffset;
        // Format
        int fmt;
        int extra;
    } Texture;

/// To simplify a bit
#define TEXTURE_ARG_LIST __global Texture const* textures, __global char const* texturedata
#define TEXTURE_ARG_LIST_IDX(x) int x, __global Texture const* textures, __global char const* texturedata
#define TEXTURE_ARGS textures, texturedata
#define TEXTURE_ARGS_IDX(x) x, textures, texturedata

/// Sample 2D texture
float3 Texture_Sample2D(float2 uv, TEXTURE_ARG_LIST_IDX(texidx))
{
    // Get width and height
    int width = textures[texidx].w;
    int height = textures[texidx].h;
    
    // Find the origin of the data in the pool
    __global char const* mydata = texturedata + textures[texidx].dataoffset;

    // Handle UV wrap
    // TODO: need UV mode support
    uv -= floor(uv);
    
    // Reverse Y:
    // it is needed as textures are loaded with Y axis going top to down
    // and our axis goes from down to top
    uv.y = 1.f - uv.y;
    
    // Calculate integer coordinates
    int x0 = floor(uv.x * width);
    int y0 = floor(uv.y * height);
    
    // Calculate samples for linear filtering
    int x1 = min(x0 + 1, width - 1);
    int y1 = min(y0 + 1, height - 1);
    
    // Calculate weights for linear filtering
    float wx = uv.x * width - floor(uv.x * width);
    float wy = uv.y * height - floor(uv.y * height);
    
    switch (textures[texidx].fmt)
    {
        case RGBA32:
        {
            __global float3 const* mydataf = (__global float3 const*)mydata;
            
            // Get 4 values for linear filtering
            float3 val00 = *(mydataf + width * y0 + x0);
            float3 val01 = *(mydataf + width * y0 + x1);
            float3 val10 = *(mydataf + width * y1 + x0);
            float3 val11 = *(mydataf + width * y1 + x1);
            
            // Filter and return the result
            return lerp(lerp(val00, val01, wx), lerp(val10, val11, wx), wy);
        }
            
        case RGBA16:
        {
            __global half const* mydatah = (__global half const*)mydata;
            
            // Get 4 values
            float3 val00 = vload_half4(width * y0 + x0, mydatah).xyz;
            float3 val01 = vload_half4(width * y0 + x1, mydatah).xyz;
            float3 val10 = vload_half4(width * y1 + x0, mydatah).xyz;
            float3 val11 = vload_half4(width * y1 + x1, mydatah).xyz;
            
            // Filter and return the result
            return lerp(lerp(val00, val01, wx), lerp(val10, val11, wx), wy);
        }
            
        case RGBA8:
        {
            __global uchar4 const* mydatac = (__global uchar4 const*)mydata;
            
            // Get 4 values and convert to float
            uchar4 valu00 = *(mydatac + width * y0 + x0);
            uchar4 valu01 = *(mydatac + width * y0 + x1);
            uchar4 valu10 = *(mydatac + width * y1 + x0);
            uchar4 valu11 = *(mydatac + width * y1 + x1);
            
            float3 val00 = make_float3((float)valu00.x / 255.f, (float)valu00.y / 255.f, (float)valu00.z / 255.f);
            float3 val01 = make_float3((float)valu01.x / 255.f, (float)valu01.y / 255.f, (float)valu01.z / 255.f);
            float3 val10 = make_float3((float)valu10.x / 255.f, (float)valu10.y / 255.f, (float)valu10.z / 255.f);
            float3 val11 = make_float3((float)valu11.x / 255.f, (float)valu11.y / 255.f, (float)valu11.z / 255.f);
            
            // Filter and return the result
            return lerp(lerp(val00, val01, wx), lerp(val10, val11, wx), wy);
        }
            
        default:
        {
            return make_float3(0.f, 0.f, 0.f);
        }
    }
}

/// Sample lattitue-longitude environment map using 3d vector
float3 Texture_SampleEnvMap(float3 d, TEXTURE_ARG_LIST_IDX(texidx))
{
    // Transform to spherical coords
    float r, phi, theta;
    CartesianToSpherical(d, &r, &phi, &theta);
    
    // Map to [0,1]x[0,1] range and reverse Y axis
    float2 uv;
    uv.x = phi / (2*PI);
    uv.y = 1.f - theta / PI;
    
    // Sample the texture
    return native_powr(Texture_Sample2D(uv, TEXTURE_ARGS_IDX(texidx)), 1.f / 1.f);
}

/// Get data from parameter value or texture
float3 Texture_GetValue3f(
                // Value
                float3 v,
                // Texture coordinate
                float2 uv,
                // Texture args
                TEXTURE_ARG_LIST_IDX(texidx)
                )
{
    // If texture present sample from texture
    if (texidx != -1)
    {
        // Sample texture
        return Texture_Sample2D(uv, TEXTURE_ARGS_IDX(texidx));
    }
    
    // Return fixed color otherwise
    return v;
}

/// Get data from parameter value or texture
float Texture_GetValue1f(
                        // Value
                        float v,
                        // Texture coordinate
                        float2 uv,
                        // Texture args
                        TEXTURE_ARG_LIST_IDX(texidx)
                        )
{
    // If texture present sample from texture
    if (texidx != -1)
    {
        // Sample texture
        return Texture_Sample2D(uv, TEXTURE_ARGS_IDX(texidx)).x;
    }
    
    // Return fixed color otherwise
    return v;
}

/// Sample 2D texture
float3 Texture_SampleBump(float2 uv, TEXTURE_ARG_LIST_IDX(texidx))
{
	// Get width and height
	int width = textures[texidx].w;
	int height = textures[texidx].h;

	// Find the origin of the data in the pool
	__global char const* mydata = texturedata + textures[texidx].dataoffset;

	// Handle UV wrap
	// TODO: need UV mode support
	uv -= floor(uv);

	// Reverse Y:
	// it is needed as textures are loaded with Y axis going top to down
	// and our axis goes from down to top
	uv.y = 1.f - uv.y;

	// Calculate integer coordinates
	int s0 = floor(uv.x * width);
	int t0 = floor(uv.y * height);

	switch (textures[texidx].fmt)
	{
	case RGBA32:
	{
		__global float3 const* mydataf = (__global float3 const*)mydata;

		// Sobel filter
		const float tex00 = (*(mydataf + width * (t0 - 1) + (s0-1))).x; 
		const float tex10 = (*(mydataf + width * (t0 - 1) + (s0))).x;
		const float tex20 = (*(mydataf + width * (t0 - 1) + (s0 + 1))).x; 

		const float tex01 = (*(mydataf + width * (t0) + (s0 - 1))).x; 
		const float tex21 = (*(mydataf + width * (t0) + (s0 + 1))).x;

		const float tex02 = (*(mydataf + width * (t0 + 1) + (s0 - 1))).x;
		const float tex12 = (*(mydataf + width * (t0 + 1) + (s0))).x;
		const float tex22 = (*(mydataf + width * (t0 + 1) + (s0 + 1))).x;

		const float Gx = tex00 - tex20 + 2.0f * tex01 - 2.0f * tex21 + tex02 - tex22;
		const float Gy = tex00 + 2.0f * tex10 + tex20 - tex02 - 2.0f * tex12 - tex22;
		const float3 n = make_float3(Gx, Gy, 1.f);

		return 0.5f * normalize(n) + make_float3(0.5f, 0.5f, 0.5f);
	}

	case RGBA16:
	{
		__global half const* mydatah = (__global half const*)mydata;

		const float tex00 = vload_half4(width * (t0 - 1) + (s0 - 1), mydatah).x;
		const float tex10 = vload_half4(width * (t0 - 1) + (s0), mydatah).x;
		const float tex20 = vload_half4(width * (t0 - 1) + (s0 + 1), mydatah).x;

		const float tex01 = vload_half4(width * (t0)+(s0 - 1), mydatah).x; 
		const float tex21 = vload_half4(width * (t0)+(s0 + 1), mydatah).x; 

		const float tex02 = vload_half4(width * (t0 + 1) + (s0 - 1), mydatah).x;
		const float tex12 = vload_half4(width * (t0 + 1) + (s0), mydatah).x;
		const float tex22 = vload_half4(width * (t0 + 1) + (s0 + 1), mydatah).x;

		const float Gx = tex00 - tex20 + 2.0f * tex01 - 2.0f * tex21 + tex02 - tex22;
		const float Gy = tex00 + 2.0f * tex10 + tex20 - tex02 - 2.0f * tex12 - tex22;
		const float3 n = make_float3(Gx, Gy, 1.f);

		return 0.5f * normalize(n) + make_float3(0.5f, 0.5f, 0.5f);
	}

	case RGBA8:
	{
		__global uchar4 const* mydatac = (__global uchar4 const*)mydata;

		const uchar utex00 = (*(mydatac + width * (t0 - 1) + (s0 - 1))).x;
		const uchar utex10 = (*(mydatac + width * (t0 - 1) + (s0))).x;
		const uchar utex20 = (*(mydatac + width * (t0 - 1) + (s0 + 1))).x;

		const uchar utex01 = (*(mydatac + width * (t0)+(s0 - 1))).x;
		const uchar utex21 = (*(mydatac + width * (t0)+(s0 + 1))).x;

		const uchar utex02 = (*(mydatac + width * (t0 + 1) + (s0 - 1))).x;
		const uchar utex12 = (*(mydatac + width * (t0 + 1) + (s0))).x;
		const uchar utex22 = (*(mydatac + width * (t0 + 1) + (s0 + 1))).x;

		const float tex00 = (float)utex00 / 255.f;
		const float tex10 = (float)utex10 / 255.f;
		const float tex20 = (float)utex20 / 255.f;

		const float tex01 = (float)utex01 / 255.f;
		const float tex21 = (float)utex21 / 255.f;

		const float tex02 = (float)utex02 / 255.f;
		const float tex12 = (float)utex12 / 255.f;
		const float tex22 = (float)utex22 / 255.f;

		const float Gx = tex00 - tex20 + 2.0f * tex01 - 2.0f * tex21 + tex02 - tex22;
		const float Gy = tex00 + 2.0f * tex10 + tex20 - tex02 - 2.0f * tex12 - tex22;
		const float3 n = make_float3(Gx, Gy, 1.f);

		return 0.5f * normalize(n) + make_float3(0.5f, 0.5f, 0.5f);
	}

	default:
	{
		return make_float3(0.f, 0.f, 0.f);
	}
	}
}



#endif // TEXTURE_CL
