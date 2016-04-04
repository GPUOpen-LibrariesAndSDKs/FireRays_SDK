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
#ifndef VOLUMETRICS_CL
#define VOLUMETRICS_CL

#include <../App/CL/payload.cl>
#include <../App/CL/path.cl>

#define FAKE_SHAPE_SENTINEL 0xFFFFFF

typedef enum
{
    kEmpty,
	kHomogeneous,
	kHeterogeneous
} VolumeType;

typedef enum
{
    kUniform,
	kRayleigh,
	kMieMurky,
	kMieHazy,
	kHG // this one requires one extra coeff
} PhaseFunction;

typedef struct _Volume
{
	VolumeType type;
	PhaseFunction phase_func;
	
	// Id of volume data if present 
	int data;
	int extra;

	// Absorbtion
	float3 sigma_a;
	// Scattering
	float3 sigma_s;
	// Emission
	float3 sigma_e;
} Volume;


// The following functions are taken from PBRT
float PhaseFunction_Uniform(float3 wi, float3 wo)
{
    return 1.f / (4.f * PI);
}

float PhaseFunction_Rayleigh(float3 wi, float3 wo)
{
	float costheta = dot(wi, wo);
	return  3.f / (16.f*PI) * (1 + costheta * costheta);
}

float PhaseFunction_MieHazy(float3 wi, float3 wo)
{
	float costheta = dot(wi, wo);
	return (0.5f + 4.5f * native_powr(0.5f * (1.f + costheta), 8.f)) / (4.f*PI);
}

float PhaseFunction_MieMurky(float3 wi, float3 wo)
{
	float costheta = dot(wi, wo);
	return (0.5f + 16.5f * native_powr(0.5f * (1.f + costheta), 32.f)) / (4.f*PI);
}

float PhaseFunction_HG(float3 wi, float3 wo, float g)
{
	float costheta = dot(wi, wo);
	return 1.f / (4.f * PI) *
		(1.f - g*g) / native_powr(1.f + g*g - 2.f * g * costheta, 1.5f);
}


// Evaluate volume transmittance along the ray [0, dist] segment
float3 Volume_Transmittance(__global Volume const* volume, __global ray const* ray, float dist)
{
    switch (volume->type)
    {
        case kHomogeneous:
        {
			// For homogeneous it is e(-sigma * dist)
            float3 sigma_t = volume->sigma_a + volume->sigma_s;
			return native_exp(-sigma_t * dist);
        }
    }
    
    return 1.f;
}

// Evaluate volume selfemission along the ray [0, dist] segment
float3 Volume_Emission(__global Volume const* volume, __global ray const* ray, float dist)
{
    switch (volume->type)
    {
        case kHomogeneous:
        {
			// For homogeneous it is simply Tr * Ev (since sigma_e is constant)
            return Volume_Transmittance(volume, ray, dist) * volume->sigma_e;
        }
    }
    
    return 0.f;
}

// Sample volume in order to find next scattering event
float Volume_SampleDistance(__global Volume const* volume, __global ray const* ray, float maxdist, float sample, float* pdf)
{
    switch (volume->type)
    {
        case kHomogeneous:
        {
			// The PDF = sigma * e(-sigma * x), so the larger sigma the closer we scatter
			float sigma = (volume->sigma_s.x + volume->sigma_s.y + volume->sigma_s.z) / 3;
			float d = sigma > 0.f ? (-native_log(sample) / sigma) : -1.f;
			*pdf = sigma > 0.f ? (sigma * native_exp(-sigma * d)) : 0.f;
			return d;
        }
    }
    
    return -1.f;
}

// Apply volume effects (absorbtion and emission) and scatter if needed.
// The rays we handling here might intersect something or miss, 
// since scattering can happen even for missed rays.
// That's why this function is called prior to ray compaction.
// In case ray has missed geometry (has shapeid < 0) and has been scattered,
// we put FAKE_SHAPE_SENTINEL into shapeid to prevent ray from being compacted away.
//
__kernel void EvaluateVolume(
	// Ray batch
	__global ray const* rays,
	// Pixel indices
	__global int const* pixelindices,
	// Number of rays
	__global int const* numrays,
	// Volumes
	__global Volume const* volumes,
	// Textures
	TEXTURE_ARG_LIST,
	// RNG seed
	int rngseed,
	// Sampler state
	__global SobolSampler* samplers,
	// Sobol matrices
	__global uint const* sobolmat,
	// Current bounce 
	int bounce,
	// Intersection data
	__global Intersection* isects,
	// Current paths
	__global Path* paths,
    // Output
    __global float3* output
	)
{
	int globalid = get_global_id(0);
	
	// Only handle active rays
	if (globalid < *numrays)
	{
        int pixelidx = pixelindices[globalid];
        
        __global Path* path = paths + pixelidx;

		// Path can be dead here since compaction step has not 
		// yet been applied
		if (!Path_IsAlive(path))
			return;

		int volidx = Path_GetVolumeIdx(path);

		// Check if we are inside some volume
		if (volidx != -1)
		{
#ifdef SOBOL
			__global SobolSampler* sampler = samplers + pixelidx;
            float sample = SobolSampler_Sample1D(sampler->seq, GetSampleDim(bounce, kVolume), sampler->s0, sobolmat);
#else
			Rng rng;
			InitRng(rngseed + (globalid << 2) * 157 + 13, &rng);
			float sample = UniformSampler_Sample2D(&rng).x;
#endif
			// Try sampling volume for a next scattering event
			float pdf = 0.f;
			float maxdist = Intersection_GetDistance(isects + globalid);
            float d = Volume_SampleDistance(&volumes[volidx], &rays[globalid], maxdist, sample, &pdf);
            
			// Check if we shall skip the event (it is either outside of a volume or not happened at all)
			bool skip = d < 0 || d > maxdist || pdf <= 0.f;

			if (skip)
			{
				// In case we skip we just need to apply volume absorbtion and emission for the segment we went through
				// and clear scatter flag
				Path_ClearScatterFlag(path);
				// Emission contribution accounting for a throughput we have so far
				Path_AddContribution(path, output, pixelidx, Volume_Emission(&volumes[volidx], &rays[globalid], maxdist));
				// And finally update the throughput
				Path_MulThroughput(path, Volume_Transmittance(&volumes[volidx], &rays[globalid], maxdist));
			}
			else
			{
				// Set scattering flag to notify ShadeVolume kernel to handle this path
				Path_SetScatterFlag(path);
				// Emission contribution accounting for a throughput we have so far
				Path_AddContribution(path, output, pixelidx, Volume_Emission(&volumes[volidx], &rays[globalid], d) / pdf);
				// Update the throughput
				Path_MulThroughput(path, (Volume_Transmittance(&volumes[volidx], &rays[globalid], d) / pdf));
				// Put fake shape to prevent from being compacted away
				isects[globalid].shapeid = FAKE_SHAPE_SENTINEL;
				// And keep scattering distance around as well
				isects[globalid].uvwt.w = d;
			}
		}
	}
}

#endif // VOLUMETRICS_CL
