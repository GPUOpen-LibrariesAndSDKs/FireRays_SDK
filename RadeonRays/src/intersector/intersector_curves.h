/**********************************************************************
Copyright (c) 2016 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/
#pragma once
#include "calc.h"
#include "device.h"
#include "intersector.h"
#include <memory>

namespace RadeonRays
{
    class Bvh;

    /** 
    \brief Curves (only) test intersector implementation using skip links BVH
    */
    class IntersectorCurves : public Intersector
    {
    public:
        // Constructor
		IntersectorCurves(Calc::Device* device);

    private:
        // Preprocess implementation
        void Process(World const& world) override;

        // Intersection implementation
        void Intersect(std::uint32_t queue_idx, Calc::Buffer const *rays, Calc::Buffer const *num_rays, 
                       std::uint32_t max_rays, Calc::Buffer *hits, 
                       Calc::Event const *wait_event, Calc::Event **event) const override;

        // Occulusion implementation
        void Occluded(std::uint32_t queue_idx, Calc::Buffer const *rays, Calc::Buffer const *num_rays, 
                      std::uint32_t max_rays, Calc::Buffer *hits, 
                      Calc::Event const *wait_event, Calc::Event **event) const override;

    private:

        struct GpuData;

        // Implementation data
        std::unique_ptr<GpuData> m_gpudata;

        // Bvh data structure
        std::unique_ptr<Bvh> m_bvh;
    };
}
