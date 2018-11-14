/*******************************************************************************
 * Copyright (c) 2015-2018 Skymind, Inc.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Apache License, Version 2.0 which is available at
 * https://www.apache.org/licenses/LICENSE-2.0.
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 ******************************************************************************/

//
// @author raver119@gmail.com
//

#include <Environment.h>
#include <loops/transform_same.h>
#include <types/types.h>
#include <op_boilerplate.h>

#include <loops/legacy_ops.h>
#include <helpers/DebugHelper.h>

using namespace simdOps;


template<typename X, typename OpClass>
__device__ void transformSameSimpleGeneric(
		Nd4jLong n,
		void *y,
		Nd4jLong incy,
		void *params,
		void *z,
		Nd4jLong resultStride, int *allocationPointer, void *reductionPointer) {

	functions::transform::TransformSame<X>::template transformCuda<OpClass>(
		n,
		y,
		incy,
		params,
		z,
		resultStride,
		allocationPointer,
		reductionPointer,
		nullptr);
}

template<typename X, typename OpClass>
__device__ void transformSameSimpleGeneric(
		void *y,
		Nd4jLong *xShapeInfo, int xRank,
		void *params,
		void *z, Nd4jLong *zShapeInfo, int zRank, int *allocationPointer, void *reductionPointer, Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {

	__shared__ UnifiedSharedMemory *manager;

	if (threadIdx.x == 0) {
		extern __shared__ unsigned char shmem[];
		manager = new(shmem) UnifiedSharedMemory((int *) shmem);
		manager->init(sizeof(UnifiedSharedMemory), 0, sizeof(functions::transform::TransformSame<X>), sizeof(shape::TAD), xRank);
	}
	__syncthreads();
	
    functions::transform::TransformSame<X>::template transformCuda<OpClass>(
	    y,
	    xShapeInfo,
	    params,
	    z,
	    zShapeInfo,
	    allocationPointer,
	    reductionPointer,
		manager, tadShapeInfo, tadOffsets);
}


template <typename X, typename OpType>
__global__ void transformSameSimple(void *y, Nd4jLong *xShapeInfo, int xRank,
								void *params,
								void *z, Nd4jLong *zShapeInfo, int zRank,
								int *allocationPointer,
								void *reductionPointer,
								Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {
	transformSameSimpleGeneric<X, OpType>(y, xShapeInfo, xRank, params, z, zShapeInfo, zRank, allocationPointer, reductionPointer, tadShapeInfo, tadOffsets);
}


namespace functions {
    namespace transform {

        template<typename X>
        _CUDA_H void TransformSame<X>::executeTransformShaped(dim3 launchDims, cudaStream_t *stream, int opNum, void *x, Nd4jLong *xShape, int xRank, void *extraParams, void *z, Nd4jLong *zShape, int zRank, int *allocationPointer, void *reductionPointer,  Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {
			DISPATCH_BY_OPNUM_T(intermediateShaped, PARAMS(launchDims, stream, x, xShape, xRank, extraParams, z, zShape, zRank, allocationPointer, reductionPointer, tadShapeInfo, tadOffsets), TRANSFORM_SAME_OPS);

            DEBUG_KERNEL(stream, opNum);
        }


        template<typename X>
        template <typename OpType>
        __device__ void TransformSame<X>::transformCuda(
			void *vdy,
			Nd4jLong *shapeInfo,
			void *vparams,
			void *vresult,
			Nd4jLong *zShapeInfo,
			int *allocationPointer, void *vreductionPointer, UnifiedSharedMemory *manager, Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {

        	auto y = static_cast<X*>(vdy);
		    auto z = static_cast<X*>(vresult);
		    auto params = static_cast<X*>(vparams);
		    auto reductionPointer = static_cast<X*>(vreductionPointer);

		    if(OpType::requiresSpecial) {
			    OpType::execSpecialCuda(y,shapeInfo,z,zShapeInfo,params, allocationPointer, reductionPointer, manager, tadShapeInfo, tadOffsets);
			    return;
		    } else {

		        auto xOrder = shape::order(shapeInfo);
		        auto zOrder = shape::order(zShapeInfo);
		        auto xEws = shape::elementWiseStride(shapeInfo);
    		    auto zEws = shape::elementWiseStride(zShapeInfo);
	    	    auto tid = blockIdx.x * blockDim.x + threadIdx.x;

                __shared__ Nd4jLong length;
		        if(threadIdx.x == 0)
			        length = shape::length(shapeInfo);
		        __syncthreads();

		        if(xEws >= 1 && zEws >= 1 && xOrder == zOrder) {
			        transformCuda<OpType>(
				    	length,
				    	y,
				    	xEws,
				    	params,
				    	z,
				    	zEws, allocationPointer, reductionPointer, manager);
		        }
		        else {
			        Nd4jLong xCoord[MAX_RANK];
			
		    	    for (Nd4jLong i = tid; i < length; i+= gridDim.x * blockDim.x) {
						
						auto xOffset2 = shape::getIndexOffset(i, shapeInfo,  length);
						auto zOffset2 = shape::getIndexOffset(i, zShapeInfo, length);
	    			    z[zOffset2] = OpType::op(y[xOffset2], params);
		    	    }
		        }
	        }
	    };

        template<typename X>
        template <typename OpType>
	    __device__ void TransformSame<X>::transformCuda(
			Nd4jLong n,
			void *vdy,
			Nd4jLong incy,
			void *vparams,
			void *vresult,
			Nd4jLong resultStride,
			int *allocationPointer, void *vreductionPointer, UnifiedSharedMemory *manager) {
		
        	auto y = static_cast<X*>(vdy);
		    auto z = static_cast<X*>(vresult);
		    auto params = static_cast<X*>(vparams);
		    auto reductionPointer = static_cast<X*>(vreductionPointer);

            int totalThreads = gridDim.x * blockDim.x;
		    Nd4jLong i = blockIdx.x * blockDim.x + threadIdx.x;

    		if(incy == 1 && resultStride == 1) {
	    		/* equal, positive, non-unit increments. */
			    for (; i < n; i += totalThreads) {
				    z[i] = OpType::op(y[i], params);
			    }
		    }
		    else {
			    for (; i < n; i += totalThreads) {
				    z[i * resultStride] = OpType::op(y[i * incy], params);
			    }
		    }
	    }


		template<typename X>
		template <typename OpType>
		_CUDA_H void TransformSame<X>::intermediateShaped(dim3 launchDims, cudaStream_t *stream, void *x, Nd4jLong *xShape, int xRank, void *extraParams, void *z, Nd4jLong *zShape, int zRank, int *allocationPointer, void *reductionPointer,  Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {
			transformSameSimple<X, OpType><<<launchDims.x, launchDims.y, launchDims.z, stream>>>(x, xShape, xRank, extraParams, z, zShape, zRank, allocationPointer, reductionPointer, tadShapeInfo, tadOffsets);
		}

        BUILD_SINGLE_TEMPLATE(template class ND4J_EXPORT TransformSame, , LIBND4J_TYPES);
    }
}
