/* -------------------------------------------------------------------------- *
 *                                   OpenMM                                   *
 * -------------------------------------------------------------------------- *
 * This is part of the OpenMM molecular simulation toolkit originating from   *
 * Simbios, the NIH National Center for Physics-Based Simulation of           *
 * Biological Structures at Stanford, funded under the NIH Roadmap for        *
 * Medical Research, grant U54 GM072970. See https://simtk.org.               *
 *                                                                            *
 * Portions copyright (c) 2009 Stanford University and the Authors.           *
 * Authors: Scott Le Grand, Peter Eastman                                     *
 * Contributors:                                                              *
 *                                                                            *
 * Permission is hereby granted, free of charge, to any person obtaining a    *
 * copy of this software and associated documentation files (the "Software"), *
 * to deal in the Software without restriction, including without limitation  *
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,   *
 * and/or sell copies of the Software, and to permit persons to whom the      *
 * Software is furnished to do so, subject to the following conditions:       *
 *                                                                            *
 * The above copyright notice and this permission notice shall be included in *
 * all copies or substantial portions of the Software.                        *
 *                                                                            *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR *
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,   *
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL    *
 * THE AUTHORS, CONTRIBUTORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,    *
 * DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR      *
 * OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE  *
 * USE OR OTHER DEALINGS IN THE SOFTWARE.                                     *
 * -------------------------------------------------------------------------- */

#include <stdio.h>
#include <cuda.h>
#include <vector_functions.h>
#include <cstdlib>
#include <string>
#include <iostream>
#include <fstream>
using namespace std;

#include "gputypes.h"

extern __shared__ Vectors sV[];
static __constant__ cudaGmxSimulation cSim;


#define DOT3(v1, v2) (v1.x * v2.x + v1.y * v2.y + v1.z * v2.z)

#define GETNORMEDDOTPRODUCT(v1, v2, dp) \
{ \
    dp          = DOT3(v1, v2); \
    float norm1 = DOT3(v1, v1); \
    float norm2 = DOT3(v2, v2); \
    dp /= sqrt(norm1 * norm2); \
    dp = min(dp, 1.0f); \
    dp = max(dp, -1.0f); \
}

#define CROSS_PRODUCT(v1, v2, c) \
    c.x = v1.y * v2.z - v1.z * v2.y; \
    c.y = v1.z * v2.x - v1.x * v2.z; \
    c.z = v1.x * v2.y - v1.y * v2.x;

#define GETPREFACTORSGIVENANGLECOSINE(cosine, param, dEdR) \
{ \
   float angle          = acos(cosine); \
   float deltaIdeal     = angle - (param.x * (3.14159265f / 180.0f)); \
   dEdR                 = param.y * deltaIdeal; \
}

#define GETANGLEBETWEENTWOVECTORS(v1, v2, angle) \
{ \
    float dp; \
    GETNORMEDDOTPRODUCT(v1, v2, dp); \
    angle = acos(dp); \
}

#define GETANGLECOSINEBETWEENTWOVECTORS(v1, v2, angle, cosine) \
{ \
    GETNORMEDDOTPRODUCT(v1, v2, cosine); \
    angle = acos(cosine); \
}

#define GETDIHEDRALANGLEBETWEENTHREEVECTORS(vector1, vector2, vector3, signVector, cp0, cp1, angle) \
{ \
    CROSS_PRODUCT(vector1, vector2, cp0); \
    CROSS_PRODUCT(vector2, vector3, cp1); \
    GETANGLEBETWEENTWOVECTORS(cp0, cp1, angle); \
    float dp = DOT3(signVector, cp1); \
    angle = (dp >= 0) ? angle : -angle; \
}                                                          

#define GETDIHEDRALANGLECOSINEBETWEENTHREEVECTORS(vector1, vector2, vector3, signVector, cp0, cp1, angle, cosine) \
{ \
    CROSS_PRODUCT(vector1, vector2, cp0); \
    CROSS_PRODUCT(vector2, vector3, cp1); \
    GETANGLECOSINEBETWEENTWOVECTORS(cp0, cp1, angle, cosine); \
    float dp = DOT3(signVector, cp1); \
    angle = (dp >= 0) ? angle : -angle; \
}

void SetCalculateLocalForcesSim(gpuContext gpu)
{
    cudaError_t status;
    status = cudaMemcpyToSymbol(cSim, &gpu->sim, sizeof(cudaGmxSimulation));     
    RTERROR(status, "cudaMemcpyToSymbol: SetSim copy to cSim failed");
}

void GetCalculateLocalForcesSim(gpuContext gpu)
{
    cudaError_t status;
    status = cudaMemcpyFromSymbol(&gpu->sim, cSim, sizeof(cudaGmxSimulation));     
    RTERROR(status, "cudaMemcpyFromSymbol: SetSim copy from cSim failed");
}
    

__global__ void kCalculateLocalForces_kernel()
{
    unsigned int pos = blockIdx.x * blockDim.x + threadIdx.x;
    Vectors* A = &sV[threadIdx.x];

    while (pos < cSim.bond_offset)
    {
        if (pos < cSim.bonds)
        {
            int4   atom         = cSim.pBondID[pos];
            float4 atomA        = cSim.pPosq[atom.x];
            float4 atomB        = cSim.pPosq[atom.y];
            float2 bond         = cSim.pBondParameter[pos];
            float dx            = atomB.x - atomA.x;
            float dy            = atomB.y - atomA.y;
            float dz            = atomB.z - atomA.z;
            float r2            = dx * dx + dy * dy + dz * dz;
            float r             = sqrt(r2);
            float deltaIdeal    = r - bond.x;
            float dEdR          = bond.y * deltaIdeal;
            dEdR                = (r > 0.0f) ? (dEdR / r) : 0.0f;
//            printf("D: %11.4f %11.4f %11.4f %11.4f %11.4f %11.4f\n", dx, dy, dz, r, deltaIdeal, dEdR);
            dx                 *= dEdR;
            dy                 *= dEdR;
            dz                 *= dEdR;
            unsigned int offsetA                = atom.x + atom.z * cSim.stride;
            unsigned int offsetB                = atom.y + atom.w * cSim.stride;
            float4 forceA                       = {0.0f, 0.0f, 0.0f, 0.0f};
            if (atom.z < cSim.totalNonbondOutputBuffers)
                forceA                          = cSim.pForce4[offsetA];
            float4 forceB                       = {0.0f, 0.0f, 0.0f, 0.0f};
            if (atom.w < cSim.totalNonbondOutputBuffers)
                forceB                          = cSim.pForce4[offsetB];
            forceA.x                           += dx;
            forceA.y                           += dy;
            forceA.z                           += dz;
            forceB.x                           -= dx;
            forceB.y                           -= dy;
            forceB.z                           -= dz;
            cSim.pForce4[offsetA]               = forceA;
            cSim.pForce4[offsetB]               = forceB;    
        }
        pos += blockDim.x * gridDim.x;
    }
  
    while (pos < cSim.bond_angle_offset)
    {
        unsigned int pos1   = pos - cSim.bond_offset;
        if (pos1 < cSim.bond_angles)
        {
            int4   atom1            = cSim.pBondAngleID1[pos1];  
            float2 bond_angle       = cSim.pBondAngleParameter[pos1];
            float4 a1               = cSim.pPosq[atom1.x];
            float4 a2               = cSim.pPosq[atom1.y];
            float4 a3               = cSim.pPosq[atom1.z];
            A->v0.x                 = a2.x - a1.x;
            A->v0.y                 = a2.y - a1.y;
            A->v0.z                 = a2.z - a1.z;
            A->v1.x                 = a2.x - a3.x;
            A->v1.y                 = a2.y - a3.y;
            A->v1.z                 = a2.z - a3.z;
            float3 cp;
            CROSS_PRODUCT(A->v0, A->v1, cp);
            float rp                = DOT3(cp, cp); //cx * cx + cy * cy + cz * cz;
            rp                      = max(sqrt(rp), 1.0e-06f);
            float r21               = DOT3(A->v0, A->v0); // dx1 * dx1 + dy1 * dy1 + dz1 * dz1;
            float r23               = DOT3(A->v1, A->v1); // dx2 * dx2 + dy2 * dy2 + dz2 * dz2;
            float dot               = DOT3(A->v0, A->v1); // dx1 * dx2 + dy1 * dy2 + dz1 * dz2;
            float cosine            = dot / sqrt(r21 * r23);
            float dEdR;
            GETPREFACTORSGIVENANGLECOSINE(cosine, bond_angle, dEdR);
            //printf("%11.4f %11.4f\n", cosine, dEdR);
            float termA             =  dEdR / (r21 * rp);
            float termC             = -dEdR / (r23 * rp);
            float3 c21;
            float3 c23;
            CROSS_PRODUCT(A->v0, cp, c21);
            CROSS_PRODUCT(A->v1, cp, c23);
            c21.x                  *= termA;
            c21.y                  *= termA;
            c21.z                  *= termA;
            c23.x                  *= termC;
            c23.y                  *= termC;
            c23.z                  *= termC;
            int2 atom2              = cSim.pBondAngleID2[pos1];
            unsigned int offset     = atom1.x + atom1.w * cSim.stride;
            float4 force            = {0.0f, 0.0f, 0.0f, 0.0f}; 
            if (atom1.w < cSim.totalNonbondOutputBuffers)
                force               = cSim.pForce4[offset]; 
            force.x                += c21.x;
            force.y                += c21.y;
            force.z                += c21.z;
            cSim.pForce4[offset]    = force;
            offset                  = atom1.y + atom2.x * cSim.stride;
            force.x                 = force.y = force.z = 0.0f; 
            if (atom2.x < cSim.totalNonbondOutputBuffers)
                force               = cSim.pForce4[offset]; 
            force.x                -= (c21.x + c23.x);
            force.y                -= (c21.y + c23.y);
            force.z                -= (c21.z + c23.z);
            cSim.pForce4[offset]    = force;
            offset                  = atom1.z + atom2.y * cSim.stride;
            force.x                 = force.y = force.z = 0.0f; 
            if (atom2.y < cSim.totalNonbondOutputBuffers)
                force               = cSim.pForce4[offset]; 
            force.x                += c23.x;
            force.y                += c23.y;
            force.z                += c23.z;
            cSim.pForce4[offset]    = force;
        }
        pos += blockDim.x * gridDim.x;
    }
            
    while (pos < cSim.dihedral_offset)
    {
        unsigned int pos1 = pos - cSim.bond_angle_offset;
        if (pos1 < cSim.dihedrals)
        {
            int4   atom1        = cSim.pDihedralID1[pos1];  
            float4 atomA        = cSim.pPosq[atom1.x];
            float4 atomB        = cSim.pPosq[atom1.y];
            float4 atomC        = cSim.pPosq[atom1.z];
            float4 atomD        = cSim.pPosq[atom1.w];            
            A->v0.x             = atomA.x - atomB.x;
            A->v0.y             = atomA.y - atomB.y;
            A->v0.z             = atomA.z - atomB.z;
            A->v1.x             = atomC.x - atomB.x;
            A->v1.y             = atomC.y - atomB.y;
            A->v1.z             = atomC.z - atomB.z;
            A->v2.x             = atomC.x - atomD.x;
            A->v2.y             = atomC.y - atomD.y;
            A->v2.z             = atomC.z - atomD.z; 
            float3 cp0, cp1;
            float dihedralAngle;
            GETDIHEDRALANGLEBETWEENTHREEVECTORS(A->v0, A->v1, A->v2, A->v0, cp0, cp1, dihedralAngle);
            float4 dihedral         = cSim.pDihedralParameter[pos1];
            float deltaAngle        = dihedral.z * dihedralAngle - (dihedral.y * 3.14159265f / 180.0f);
            float sinDeltaAngle     = sin(deltaAngle);
            float dEdAngle          = -dihedral.x * dihedral.z * sinDeltaAngle;
            float normCross1        = DOT3(cp0, cp0);
            float normBC            = sqrt(DOT3(A->v1, A->v1));
            float4 ff;
            ff.x                    = (-dEdAngle * normBC) / normCross1;
            float normCross2        = DOT3(cp1, cp1);
            ff.w                    = (dEdAngle * normBC) / normCross2;
            float dp                = 1.0f / DOT3(A->v1, A->v1);
            ff.y                    = DOT3(A->v0, A->v1) * dp;
            ff.z                    = DOT3(A->v2, A->v1) * dp;
            int4  atom2             = cSim.pDihedralID2[pos1];   
            float3 internalF0;
            float3 internalF3;
            float3 s;
            
//            printf("%4d: %9.4f %9.4f %9.4f %9.4f\n", pos1, ff.x, ff.y, ff.z, ff.w);  
            unsigned int offset                 = atom1.x + atom2.x * cSim.stride;
            float4 force                        = {0.0f, 0.0f, 0.0f, 0.0f}; 
            if (atom2.x < cSim.totalNonbondOutputBuffers)
                force                           = cSim.pForce4[offset]; 
            internalF0.x                        = ff.x * cp0.x; 
            force.x                            += internalF0.x;
            internalF0.y                        = ff.x * cp0.y;
            force.y                            += internalF0.y;
            internalF0.z                        = ff.x * cp0.z;       
            force.z                            += internalF0.z;
            cSim.pForce4[offset]                = force;
            
            //printf("%4d - 0: %9.4f %9.4f %9.4f\n", pos1, cSim.pForce[offset], cSim.pForce[offset + cSim.stride], cSim.pForce[offset + cSim.stride2]);
            offset                              = atom1.w + atom2.w * cSim.stride;
            force.x                             = force.y = force.z = 0.0f;  
            if (atom2.w < cSim.totalNonbondOutputBuffers)
                force                           = cSim.pForce4[offset]; 
            internalF3.x                        = ff.w * cp1.x;
            force.x                            += internalF3.x;
            internalF3.y                        = ff.w * cp1.y;
            force.y                            += internalF3.y;
            internalF3.z                        = ff.w * cp1.z;
            force.z                            += internalF3.z;
            cSim.pForce4[offset]                = force;
            
           // printf("%4d - 3: %9.4f %9.4f %9.4f\n", pos1, cSim.pForce[offset], cSim.pForce[offset + cSim.stride], cSim.pForce[offset + cSim.stride2]);
            s.x                                 = ff.y * internalF0.x - ff.z * internalF3.x;   
            s.y                                 = ff.y * internalF0.y - ff.z * internalF3.y;  
            s.z                                 = ff.y * internalF0.z - ff.z * internalF3.z;        
            offset                              = atom1.y + atom2.y * cSim.stride;
            force.x                             = force.y = force.z = 0.0f; 
            if (atom2.y < cSim.totalNonbondOutputBuffers)
                force                           = cSim.pForce4[offset]; 
            force.x                            += -internalF0.x + s.x;
            force.y                            += -internalF0.y + s.y;
            force.z                            += -internalF0.z + s.z;
            cSim.pForce4[offset]                = force;
            
            //printf("%4d - 1: %9.4f %9.4f %9.4f\n", pos1, cSim.pForce[offset], cSim.pForce[offset + cSim.stride], cSim.pForce[offset + cSim.stride2]);
            offset                              = atom1.z + atom2.z * cSim.stride;
            force.x                             = force.y = force.z = 0.0f; 
            if (atom2.z < cSim.totalNonbondOutputBuffers)
                force                           = cSim.pForce4[offset]; 
            force.x                            += -internalF3.x - s.x;
            force.y                            += -internalF3.y - s.y;
            force.z                            += -internalF3.z - s.z;
            cSim.pForce4[offset]                = force;
            //printf("%4d - 2: %9.4f %9.4f %9.4f\n", pos1, cSim.pForce[offset], cSim.pForce[offset + cSim.stride], cSim.pForce[offset + cSim.stride2]);
        }        
        pos += blockDim.x * gridDim.x;
    }

    while (pos < cSim.rb_dihedral_offset)
    {
        unsigned int pos1 = pos - cSim.dihedral_offset;
        if (pos1 < cSim.rb_dihedrals)
        {
            int4   atom1        = cSim.pRbDihedralID1[pos1];  
            float4 atomA        = cSim.pPosq[atom1.x];
            float4 atomB        = cSim.pPosq[atom1.y];
            float4 atomC        = cSim.pPosq[atom1.z];
            float4 atomD        = cSim.pPosq[atom1.w];            
            A->v0.x             = atomA.x - atomB.x;
            A->v0.y             = atomA.y - atomB.y;
            A->v0.z             = atomA.z - atomB.z;
            A->v1.x             = atomC.x - atomB.x;
            A->v1.y             = atomC.y - atomB.y;
            A->v1.z             = atomC.z - atomB.z;
            A->v2.x             = atomC.x - atomD.x;
            A->v2.y             = atomC.y - atomD.y;
            A->v2.z             = atomC.z - atomD.z; 
            float3 cp0, cp1;
            float dihedralAngle, cosPhi;
      //      printf("%4d - 0 : %9.4f %9.4f %9.4f\n", pos1, A->v0.x, A->v0.y, A->v0.z); 
      //      printf("%4d - 1 : %9.4f %9.4f %9.4f\n", pos1, A->v1.x, A->v1.y, A->v1.z); 
      //      printf("%4d - 2 : %9.4f %9.4f %9.4f\n", pos1, A->v2.x, A->v2.y, A->v2.z);  
            GETDIHEDRALANGLECOSINEBETWEENTHREEVECTORS(A->v0, A->v1, A->v2, A->v0, cp0, cp1, dihedralAngle, cosPhi);
            if (dihedralAngle < 0.0f )
            {
                dihedralAngle += 3.14159265f;
            } 
            else 
            {
                dihedralAngle -= 3.14159265f;
            }
            cosPhi                  = -cosPhi;
         //   printf("%4d: %9.4f %9.4f\n", pos1, dihedralAngle, cosPhi);
            float4 dihedral1        = cSim.pRbDihedralParameter1[pos1];
            float2 dihedral2        = cSim.pRbDihedralParameter2[pos1];
            float cosFactor         = cosPhi;
            float dEdAngle          = -dihedral1.y;
        //    printf("%4d - 1: %9.4f %9.4f\n", pos1, dEdAngle, 1.0f);
            dEdAngle               -= 2.0f * dihedral1.z * cosFactor;
       //     printf("%4d - 2: %9.4f %9.4f\n", pos1, dEdAngle, cosFactor);
            cosFactor              *= cosPhi;
            dEdAngle               -= 3.0f * dihedral1.w * cosFactor;
     //       printf("%4d - 3: %9.4f %9.4f\n", pos1, dEdAngle, cosFactor);
            cosFactor              *= cosPhi;
            dEdAngle               -= 4.0f * dihedral2.x * cosFactor;
   //         printf("%4d - 4: %9.4f %9.4f\n", pos1, dEdAngle, cosFactor);
            cosFactor              *= cosPhi;
            dEdAngle               -= 5.0f * dihedral2.y * cosFactor;
 //           printf("%4d - 5: %9.4f %9.4f\n", pos1, dEdAngle, cosFactor);
            dEdAngle               *= sin(dihedralAngle);  
//            printf("%4d - f: %9.4f\n", pos1, dEdAngle);
            
            float normCross1        = DOT3(cp0, cp0);
            float normBC            = sqrt(DOT3(A->v1, A->v1));
            float4 ff;
            ff.x                    = (-dEdAngle * normBC) / normCross1;
            float normCross2        = DOT3(cp1, cp1);
            ff.w                    = (dEdAngle * normBC) / normCross2;
            float dp                = 1.0f / DOT3(A->v1, A->v1);
            ff.y                    = DOT3(A->v0, A->v1) * dp;
            ff.z                    = DOT3(A->v2, A->v1) * dp;
            int4  atom2             = cSim.pRbDihedralID2[pos1];   
            float3 internalF0;
            float3 internalF3;
            float3 s;
            
//            printf("%4d: %9.4f %9.4f %9.4f %9.4f\n", pos1, ff.x, ff.y, ff.z, ff.w);  
            unsigned int offset                 = atom1.x + atom2.x * cSim.stride;
            float4 force                        = {0.0f, 0.0f, 0.0f, 0.0f}; 
            if (atom2.x < cSim.totalNonbondOutputBuffers)
                force                           = cSim.pForce4[offset]; 
            internalF0.x                        = ff.x * cp0.x; 
            force.x                            += internalF0.x;
            internalF0.y                        = ff.x * cp0.y;
            force.y                            += internalF0.y;
            internalF0.z                        = ff.x * cp0.z;       
            force.z                            += internalF0.z;
            cSim.pForce4[offset]                = force;
            
 //           printf("%4d - 0: %9.4f %9.4f %9.4f\n", pos1, cSim.pForce[offset], cSim.pForce[offset + cSim.stride], cSim.pForce[offset + cSim.stride2]);
            offset                              = atom1.w + atom2.w * cSim.stride;
            force.x                             = force.y = force.z = 0.0f; 
            if (atom2.w < cSim.totalNonbondOutputBuffers)
                force                           = cSim.pForce4[offset]; 
            internalF3.x                        = ff.w * cp1.x;
            force.x                            += internalF3.x;
            internalF3.y                        = ff.w * cp1.y;
            force.y                            += internalF3.y;
            internalF3.z                        = ff.w * cp1.z;
            force.z                            += internalF3.z;
            cSim.pForce4[offset]                = force;
            
   //         printf("%4d - 3: %9.4f %9.4f %9.4f\n", pos1, cSim.pForce[offset], cSim.pForce[offset + cSim.stride], cSim.pForce[offset + cSim.stride2]);
            s.x                                 = ff.y * internalF0.x - ff.z * internalF3.x;   
            s.y                                 = ff.y * internalF0.y - ff.z * internalF3.y;  
            s.z                                 = ff.y * internalF0.z - ff.z * internalF3.z;        
            offset                              = atom1.y + atom2.y * cSim.stride;
            force.x                             = force.y = force.z = 0.0f; 
            if (atom2.y < cSim.totalNonbondOutputBuffers)
                force                           = cSim.pForce4[offset]; 
            force.x                            += -internalF0.x + s.x;
            force.y                            += -internalF0.y + s.y;
            force.z                            += -internalF0.z + s.z;
            cSim.pForce4[offset]                = force;
     //       printf("%4d - 1: %9.4f %9.4f %9.4f\n", pos1, cSim.pForce[offset], cSim.pForce[offset + cSim.stride], cSim.pForce[offset + cSim.stride2]);
            offset                              = atom1.z + atom2.z * cSim.stride;
            force.x                             = force.y = force.z = 0.0f; 
            if (atom2.z < cSim.totalNonbondOutputBuffers)
                force                           = cSim.pForce4[offset]; 
            force.x                            += -internalF3.x - s.x;
            force.y                            += -internalF3.y - s.y;
            force.z                            += -internalF3.z - s.z;
            cSim.pForce4[offset]                = force;
     //       printf("%4d - 2: %9.4f %9.4f %9.4f\n", pos1, cSim.pForce[offset], cSim.pForce[offset + cSim.stride], cSim.pForce[offset + cSim.stride2]);
        }            
        pos += blockDim.x * gridDim.x;
    }   

    if (cSim.nonbondedMethod == NO_CUTOFF)
    {
        while (pos < cSim.LJ14_offset)
        {
            unsigned int pos1       = pos - cSim.rb_dihedral_offset;
            if (pos1 < cSim.LJ14s)
            {
                int4 atom               = cSim.pLJ14ID[pos1];
                float4 LJ14             = cSim.pLJ14Parameter[pos1];
                float4 a1               = cSim.pPosq[atom.x];
                float4 a2               = cSim.pPosq[atom.y];
                float3 d;
                d.x                     = a1.x - a2.x;
                d.y                     = a1.y - a2.y;
                d.z                     = a1.z - a2.z;
                float r2                = DOT3(d, d);
                float inverseR          = 1.0f / sqrt(r2);
                float sig2              = inverseR * LJ14.y;
                sig2                   *= sig2;
                float sig6              = sig2 * sig2 * sig2;
                float dEdR              = LJ14.x * (12.0f * sig6 - 6.0f) * sig6;
                dEdR                   += LJ14.z * inverseR;
                dEdR                   *= inverseR * inverseR;
                unsigned int offsetA    = atom.x + atom.z * cSim.stride;
                unsigned int offsetB    = atom.y + atom.w * cSim.stride;
                float4 forceA           = {0.0f, 0.0f, 0.0f, 0.0f};
                if (atom.z < cSim.totalNonbondOutputBuffers)
                    forceA              = cSim.pForce4[offsetA];
                float4 forceB           = {0.0f, 0.0f, 0.0f, 0.0f};
                if (atom.w < cSim.totalNonbondOutputBuffers)
                    forceB              = cSim.pForce4[offsetB];
                d.x                    *= dEdR;
                d.y                    *= dEdR;
                d.z                    *= dEdR;
                forceA.x               += d.x;
                forceA.y               += d.y;
                forceA.z               += d.z;
                forceB.x               -= d.x;
                forceB.y               -= d.y;
                forceB.z               -= d.z;
                cSim.pForce4[offsetA]   = forceA;
                cSim.pForce4[offsetB]   = forceB;
            }
            pos                    += blockDim.x * gridDim.x;
        }
    }
    else if (cSim.nonbondedMethod == CUTOFF)
    {
        while (pos < cSim.LJ14_offset)
        {
            unsigned int pos1       = pos - cSim.rb_dihedral_offset;
            if (pos1 < cSim.LJ14s)
            {
                int4 atom               = cSim.pLJ14ID[pos1];
                float4 LJ14             = cSim.pLJ14Parameter[pos1];
                float4 a1               = cSim.pPosq[atom.x];
                float4 a2               = cSim.pPosq[atom.y];
                float3 d;
                d.x                     = a1.x - a2.x;
                d.y                     = a1.y - a2.y;
                d.z                     = a1.z - a2.z;
                float r2                = DOT3(d, d);
                float inverseR          = 1.0f / sqrt(r2);
                float sig2              = inverseR * LJ14.y;
                sig2                   *= sig2;
                float sig6              = sig2 * sig2 * sig2;
                float dEdR              = LJ14.x * (12.0f * sig6 - 6.0f) * sig6;
                dEdR                   += LJ14.z * (inverseR - 2.0f * cSim.reactionFieldK * r2);
                dEdR                   *= inverseR * inverseR;
                if (r2 > cSim.nonbondedCutoffSqr)
                {
                    dEdR = 0.0f;
                }
                unsigned int offsetA    = atom.x + atom.z * cSim.stride;
                unsigned int offsetB    = atom.y + atom.w * cSim.stride;
                float4 forceA           = {0.0f, 0.0f, 0.0f, 0.0f};
                if (atom.z < cSim.totalNonbondOutputBuffers)
                    forceA              = cSim.pForce4[offsetA];
                float4 forceB           = {0.0f, 0.0f, 0.0f, 0.0f};
                if (atom.w < cSim.totalNonbondOutputBuffers)
                    forceB              = cSim.pForce4[offsetB];
                d.x                    *= dEdR;
                d.y                    *= dEdR;
                d.z                    *= dEdR;
                forceA.x               += d.x;
                forceA.y               += d.y;
                forceA.z               += d.z;
                forceB.x               -= d.x;
                forceB.y               -= d.y;
                forceB.z               -= d.z;
                cSim.pForce4[offsetA]   = forceA;
                cSim.pForce4[offsetB]   = forceB;
            }
            pos                    += blockDim.x * gridDim.x;
        }
    }
    else if (cSim.nonbondedMethod == PERIODIC)
    {
        while (pos < cSim.LJ14_offset)
        {
            unsigned int pos1       = pos - cSim.rb_dihedral_offset;
            if (pos1 < cSim.LJ14s)
            {
                int4 atom               = cSim.pLJ14ID[pos1];
                float4 LJ14             = cSim.pLJ14Parameter[pos1];
                float4 a1               = cSim.pPosq[atom.x];
                float4 a2               = cSim.pPosq[atom.y];
                float3 d;
                d.x                     = a1.x - a2.x;
                d.y                     = a1.y - a2.y;
                d.z                     = a1.z - a2.z;
                d.x                     -= floor(d.x/cSim.periodicBoxSizeX+0.5f)*cSim.periodicBoxSizeX;
                d.y                     -= floor(d.x/cSim.periodicBoxSizeY+0.5f)*cSim.periodicBoxSizeY;
                d.z                     -= floor(d.x/cSim.periodicBoxSizeZ+0.5f)*cSim.periodicBoxSizeZ;
                float r2                = DOT3(d, d);
                float inverseR          = 1.0f / sqrt(r2);
                float sig2              = inverseR * LJ14.y;
                sig2                   *= sig2;
                float sig6              = sig2 * sig2 * sig2;
                float dEdR              = LJ14.x * (12.0f * sig6 - 6.0f) * sig6;
                dEdR                   += LJ14.z * (inverseR - 2.0f * cSim.reactionFieldK * r2);
                dEdR                   *= inverseR * inverseR;
                if (r2 > cSim.nonbondedCutoffSqr)
                {
                    dEdR = 0.0f;
                }
                unsigned int offsetA    = atom.x + atom.z * cSim.stride;
                unsigned int offsetB    = atom.y + atom.w * cSim.stride;
                float4 forceA           = {0.0f, 0.0f, 0.0f, 0.0f};
                if (atom.z < cSim.totalNonbondOutputBuffers)
                    forceA              = cSim.pForce4[offsetA];
                float4 forceB           = {0.0f, 0.0f, 0.0f, 0.0f};
                if (atom.w < cSim.totalNonbondOutputBuffers)
                    forceB              = cSim.pForce4[offsetB];
                d.x                    *= dEdR;
                d.y                    *= dEdR;
                d.z                    *= dEdR;
                forceA.x               += d.x;
                forceA.y               += d.y;
                forceA.z               += d.z;
                forceB.x               -= d.x;
                forceB.y               -= d.y;
                forceB.z               -= d.z;
                cSim.pForce4[offsetA]   = forceA;
                cSim.pForce4[offsetB]   = forceB;
            }
            pos                    += blockDim.x * gridDim.x;
        }
    }

}

void kCalculateLocalForces(gpuContext gpu)
{
  //  printf("kCalculateLocalForces\n");
    kCalculateLocalForces_kernel<<<gpu->sim.blocks, gpu->sim.localForces_threads_per_block, gpu->sim.localForces_threads_per_block * sizeof(Vectors)>>>();
    LAUNCHERROR("kCalculateLocalForces");
}
