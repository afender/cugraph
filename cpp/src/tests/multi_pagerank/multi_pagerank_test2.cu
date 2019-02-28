/*
 * Copyright (c) 2018, NVIDIA CORPORATION.  All rights reserved.
 *
 * NVIDIA CORPORATION and its licensors retain all intellectual property
 * and proprietary rights in and to this software, related documentation
 * and any modifications thereto.  Any use, reproduction, disclosure or
 * distribution of this software and related documentation without an express
 * license agreement from NVIDIA CORPORATION is strictly prohibited.
 *
 */

// Pagerank solver tests
// Author: Alex Fender afender@nvidia.com

#include <mpi.h>
#include <algorithm>
#include "gtest/gtest.h"
#include <cugraph.h>
#include "cuda_profiler_api.h"
#include "test_utils.h"

TEST(MultiPagerank, imb32_32B_2ranks)
{
  int rank, ntask;
  MPI_Comm_size(MPI_COMM_WORLD, &ntask);
  ASSERT_EQ(ntask,2) << "This test works for 2 MPI processes"<< "\n";
  MPI_Comm_rank(MPI_COMM_WORLD, &rank);
  size_t loc_v, loc_e, global_v = 32;
  float damping_factor=0.85;
  int max_iter=30;


  std::vector<int> src_h, dest_h, v_idx;
  std::vector<float> pagerank, nx_ref;


  // This input data was generated from PRbench code
  // ibm data set is plit between rank 0 and 1 so they have a similar number of edges
  // Same destinations (keys) cannot be on 2 partitions not cut 
  // Here for instance 126/2 = 63, so for rank0 we cut at vertex 12 which correspond to 62 edges 
  if(rank == 0) {
    loc_v = 13;
    loc_e = 62;
    src_h={0,1,2,3,6,25,0,1,8,20,27,1,2,5,7,8,28,2,3,4,11,2,4,22,26,0,5,15,2,6,13,20,30,0,7,11,16,26,6,8,9,12,18,22,26,0,9,10,20,22,24,26,1,10,14,17,28,5,11,23,10,12};
    dest_h={0,0,0,0,0,0,1,1,1,1,1,2,2,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,6,6,6,6,6,7,7,7,7,7,8,8,8,8,8,8,8,9,9,9,9,9,9,9,10,10,10,10,10,11,11,11,12,12};
    nx_ref={0.0438673505,0.0448996131,0.0529609128,0.0215618329,0.0214298682,0.0181317262,0.0381081597,0.0272124501,0.0756169741,0.0746216296,0.0505499903,0.0124205849,0.0195928545};
  }
  if (rank== 1) {
    loc_v = 19;
    loc_e = 64;
    src_h={2,13,1,14,19,3,15,21,3,15,16,5,9,17,19,29,0,18,25,7,15,19,2,20,31,10,21,1,16,20,22,11,23,25,5,14,17,23,24,12,17,21,25,4,23,25,26,8,27,2,4,26,28,31,11,16,22,29,12,13,30,23,27,31};
    dest_h={13,13,14,14,14,15,15,15,16,16,16,17,17,17,17,17,18,18,18,19,19,19,20,20,20,21,21,22,22,22,22,23,23,23,24,24,24,24,24,25,25,25,25,26,26,26,26,27,27,28,28,28,28,28,29,29,29,29,30,30,30,31,31,31};
    nx_ref={0.0143924609,0.0245432364,0.0195166656,0.0170370551,0.0582662552,0.0286961279,0.0230860265,0.0197781389,0.0215293575,0.0217240197,0.0149364236,0.0515557942,0.0329307776,0.0202471120,0.0289620096,0.0332623858,0.0245434036,0.0224849487,0.0215338530};
  }

  pagerank.resize(loc_v);
  v_idx.resize(loc_v);

  //Check input sizes
  ASSERT_EQ(src_h.size(),dest_h.size());
  ASSERT_EQ(src_h.size(),loc_e);
  ASSERT_EQ(nx_ref.size(),loc_v);

  gdf_column *col_src = new gdf_column, 
             *col_dest = new gdf_column, 
             *col_pagerank = new gdf_column, 
             *col_vidx = new gdf_column;

  create_gdf_column(pagerank, col_pagerank);
  create_gdf_column(v_idx, col_vidx);
  create_gdf_column(src_h, col_src);
  create_gdf_column(dest_h, col_dest);

  ASSERT_EQ(gdf_multi_pagerank (global_v, col_src, col_dest, col_vidx, col_pagerank, damping_factor, max_iter),GDF_SUCCESS);

  std::vector<float> calculated_res(loc_v);
  CUDA_RT_CALL(cudaMemcpy(&calculated_res[0],   col_pagerank->data,   sizeof(float) * loc_v, cudaMemcpyDeviceToHost));

  float err;
  int n_err = 0;
  for (int i = 0; i < loc_v; i++)
  {
      std::cout<< rank<<" " << i<<" " <<nx_ref[i]<<" "<<calculated_res[i]<<std::endl;

      err = fabs(nx_ref[i] - calculated_res[i]);
      if (err> 1e-6f)
      {
          n_err++;
      }
  }
  MPI_Barrier(MPI_COMM_WORLD);

  if (n_err)
  {
      EXPECT_LE(n_err, 0); 
  }

  gdf_col_delete(col_src);
  gdf_col_delete(col_dest);
  gdf_col_delete(col_pagerank);
  gdf_col_delete(col_vidx);
}

int main(int argc, char **argv)  {

  srand(42);
  ::testing::InitGoogleTest(&argc, argv);
  MPI_Init(&argc, &argv);
  
  int r = RUN_ALL_TESTS();
  MPI_Finalize();
  return r;
}
