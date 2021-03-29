/*
 * Copyright (c) 2020-2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <algorithms.hpp>
#include <cstddef>
#include <experimental/graph_view.hpp>
#include <patterns/reduce_op.cuh>
#include <patterns/update_frontier_v_push_if_out_nbr.cuh>
#include <patterns/vertex_frontier.cuh>
#include <utilities/error.hpp>
#include <vertex_partition_device.cuh>

#include <rmm/thrust_rmm_allocator.h>
#include <raft/handle.hpp>

#include <thrust/fill.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/discard_iterator.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/transform.h>
#include <thrust/tuple.h>

#include <limits>
#include <type_traits>

namespace cugraph {
namespace experimental {
namespace detail {

template <typename GraphViewType, typename PredecessorIterator>
void ms_bfs(raft::handle_t const &handle,
            GraphViewType const &push_graph_view,
            typename GraphViewType::vertex_type *distances,
            PredecessorIterator predecessor_first,
            typename GraphViewType::vertex_type *sources,
            size_t n_sources,
            bool direction_optimizing,
            typename GraphViewType::vertex_type depth_limit,
            bool do_expensive_check)
{
  using vertex_t = typename GraphViewType::vertex_type;

  static_assert(std::is_integral<vertex_t>::value,
                "GraphViewType::vertex_type should be integral.");
  static_assert(!GraphViewType::is_adj_matrix_transposed,
                "GraphViewType should support the push model.");

  auto const num_vertices = push_graph_view.get_number_of_vertices();
  if (num_vertices == 0) { return; }

  // 1. check input arguments

  CUGRAPH_EXPECTS(
    push_graph_view.is_symmetric() || !direction_optimizing,
    "Invalid input argument: input graph should be symmetric for direction optimizing BFS.");
  CUGRAPH_EXPECTS(push_graph_view.is_valid_vertex(sources),
                  "Invalid input argument: source vertex out-of-range.");
  CUGRAPH_EXPECTS(n_sources > 1, "Invalid input argument: input should have more than one source");
  CUGRAPH_EXPECTS(sources != nullptr, "Invalid input argument: sources cannot be null");
  if (do_expensive_check) {
    vertex_partition_device_t<GraphViewType> vertex_partition(push_graph_view);
    auto num_invalid_vertices =
      count_if_v(handle,
                 push_graph_view,
                 sources,
                 sources + n_sources,
                 [vertex_partition] __device__(auto val) {
                   return !(vertex_partition.is_valid_vertex(val) &&
                            vertex_partition.is_local_vertex_nocheck(val));
                 });
    CUGRAPH_EXPECTS(num_invalid_vertices == 0,
                    "Invalid input argument: sources have invalid vertex IDs.");
  }

  // 2. initialize distances and predecessors

  thrust::fill(distances,
               distances + push_graph_view.get_number_of_local_vertices(),
               std::numeric_limits<vertex_t>::max());
  thrust::fill(distances,
               distances + push_graph_view.get_number_of_local_vertices(),
               invalid_vertex_id<vertex_t>::value);
  thrust::for_each(
    rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
    sources,
    sources + n_sources,
    [vertex_partition, pageranks, dangling_sum, personalization_sum, alpha] __device__(auto val) {
      auto v     = thrust::get<0>(val);
      auto value = thrust::get<1>(val);
      *(pageranks + vertex_partition.get_local_vertex_offset_from_vertex_nocheck(v)) +=
        (dangling_sum * alpha + static_cast<result_t>(1.0 - alpha)) * (value / personalization_sum);
    });
  auto val_first = thrust::make_zip_iterator(thrust::make_tuple(distances, predecessor_first));

  thrust::transform(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                    thrust::make_counting_iterator(push_graph_view.get_local_vertex_first()),
                    thrust::make_counting_iterator(push_graph_view.get_local_vertex_last()),
                    val_first,
                    [sources] __device__(auto val) {
                      auto distance = invalid_distance;
                      if (val == sources) { distance = vertex_t{0}; }
                      return thrust::make_tuple(distance, invalid_vertex);
                    });

  // 3. initialize BFS frontier

  enum class Bucket { cur, num_buckets };
  std::vector<size_t> bucket_sizes(static_cast<size_t>(Bucket::num_buckets),
                                   push_graph_view.get_number_of_local_vertices());
  VertexFrontier<thrust::tuple<vertex_t>,
                 vertex_t,
                 GraphViewType::is_multi_gpu,
                 static_cast<size_t>(Bucket::num_buckets)>
    vertex_frontier(handle, bucket_sizes);

  if (push_graph_view.is_local_vertex_nocheck(sources)) {
    vertex_frontier.get_bucket(static_cast<size_t>(Bucket::cur)).insert(sources);
  }

  // 4. BFS iteration

  vertex_t depth{0};
  auto cur_local_vertex_frontier_first =
    vertex_frontier.get_bucket(static_cast<size_t>(Bucket::cur)).begin();
  auto cur_vertex_frontier_aggregate_size =
    vertex_frontier.get_bucket(static_cast<size_t>(Bucket::cur)).aggregate_size();
  while (true) {
    if (direction_optimizing) {
      CUGRAPH_FAIL("unimplemented.");
    } else {
      vertex_partition_device_t<GraphViewType> vertex_partition(push_graph_view);

      auto cur_local_vertex_frontier_last =
        vertex_frontier.get_bucket(static_cast<size_t>(Bucket::cur)).end();
      update_frontier_v_push_if_out_nbr(
        handle,
        push_graph_view,
        cur_local_vertex_frontier_first,
        cur_local_vertex_frontier_last,
        thrust::make_constant_iterator(0) /* dummy */,
        thrust::make_constant_iterator(0) /* dummy */,
        [vertex_partition, distances] __device__(
          vertex_t src, vertex_t dst, auto src_val, auto dst_val) {
          auto push = true;
          if (vertex_partition.is_local_vertex_nocheck(dst)) {
            auto distance =
              *(distances + vertex_partition.get_local_vertex_offset_from_vertex_nocheck(dst));
            if (distance != invalid_distance) { push = false; }
          }
          // FIXME: need to test this works properly if payload size is 0 (returns a tuple of size
          // 1)
          return thrust::make_tuple(push, src);
        },
        reduce_op::any<thrust::tuple<vertex_t>>(),
        distances,
        thrust::make_zip_iterator(thrust::make_tuple(distances, predecessor_first)),
        vertex_frontier,
        [depth] __device__(auto v_val, auto pushed_val) {
          auto idx = (v_val == invalid_distance)
                       ? static_cast<size_t>(Bucket::cur)
                       : VertexFrontier<thrust::tuple<vertex_t>, vertex_t>::kInvalidBucketIdx;
          return thrust::make_tuple(idx, depth + 1, thrust::get<0>(pushed_val));
        });

      auto new_vertex_frontier_aggregate_size =
        vertex_frontier.get_bucket(static_cast<size_t>(Bucket::cur)).aggregate_size() -
        cur_vertex_frontier_aggregate_size;
      if (new_vertex_frontier_aggregate_size == 0) { break; }

      cur_local_vertex_frontier_first = cur_local_vertex_frontier_last;
      cur_vertex_frontier_aggregate_size += new_vertex_frontier_aggregate_size;
    }

    depth++;
    if (depth >= depth_limit) { break; }
  }

  CUDA_TRY(cudaStreamSynchronize(
    handle.get_stream()));  // this is as necessary vertex_frontier will become out-of-scope once
                            // this function returns (FIXME: should I stream sync in VertexFrontier
                            // destructor?)
}

}  // namespace detail

template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
void ms_bfs(raft::handle_t const &handle,
            graph_view_t<vertex_t, edge_t, weight_t, false, multi_gpu> const &graph_view,
            vertex_t *distances,
            vertex_t *predecessors,
            vertex_t *sources,
            size_t n_sources,
            bool direction_optimizing,
            vertex_t depth_limit,
            bool do_expensive_check)
{
  if (predecessors != nullptr) {
    detail::ms_bfs(handle,
                   graph_view,
                   distances,
                   predecessors,
                   sources,
                   n_sources,
                   direction_optimizing,
                   depth_limit,
                   do_expensive_check);
  } else {
    detail::ms_bfs(handle,
                   graph_view,
                   distances,
                   thrust::make_discard_iterator(),
                   sources,
                   n_sources,
                   direction_optimizing,
                   depth_limit,
                   do_expensive_check);
  }
}

// explicit instantiation

template void ms_bfs(raft::handle_t const &handle,
                     graph_view_t<int32_t, int32_t, float, false, true> const &graph_view,
                     int32_t *distances,
                     int32_t *predecessors,
                     int32_t *sources,
                     size_t n_sources,
                     bool direction_optimizing,
                     int32_t depth_limit,
                     bool do_expensive_check);

template void ms_bfs(raft::handle_t const &handle,
                     graph_view_t<int32_t, int32_t, double, false, true> const &graph_view,
                     int32_t *distances,
                     int32_t *predecessors,
                     int32_t *sources,
                     size_t n_sources,
                     bool direction_optimizing,
                     int32_t depth_limit,
                     bool do_expensive_check);

template void ms_bfs(raft::handle_t const &handle,
                     graph_view_t<int32_t, int64_t, float, false, true> const &graph_view,
                     int32_t *distances,
                     int32_t *predecessors,
                     int32_t *sources,
                     size_t n_sources,
                     bool direction_optimizing,
                     int32_t depth_limit,
                     bool do_expensive_check);

template void ms_bfs(raft::handle_t const &handle,
                     graph_view_t<int32_t, int64_t, double, false, true> const &graph_view,
                     int32_t *distances,
                     int32_t *predecessors,
                     int32_t *sources,
                     size_t n_sources,
                     bool direction_optimizing,
                     int32_t depth_limit,
                     bool do_expensive_check);

template void ms_bfs(raft::handle_t const &handle,
                     graph_view_t<int64_t, int64_t, float, false, true> const &graph_view,
                     int64_t *distances,
                     int64_t *predecessors,
                     int64_t *sources,
                     size_t n_sources,
                     bool direction_optimizing,
                     int64_t depth_limit,
                     bool do_expensive_check);

template void ms_bfs(raft::handle_t const &handle,
                     graph_view_t<int64_t, int64_t, double, false, true> const &graph_view,
                     int64_t *distances,
                     int64_t *predecessors,
                     int64_t *sources,
                     size_t n_sources,
                     bool direction_optimizing,
                     int64_t depth_limit,
                     bool do_expensive_check);

template void ms_bfs(raft::handle_t const &handle,
                     graph_view_t<int32_t, int32_t, float, false, false> const &graph_view,
                     int32_t *distances,
                     int32_t *predecessors,
                     int32_t *sources,
                     size_t n_sources,
                     bool direction_optimizing,
                     int32_t depth_limit,
                     bool do_expensive_check);

template void ms_bfs(raft::handle_t const &handle,
                     graph_view_t<int32_t, int32_t, double, false, false> const &graph_view,
                     int32_t *distances,
                     int32_t *predecessors,
                     int32_t *sources,
                     size_t n_sources,
                     bool direction_optimizing,
                     int32_t depth_limit,
                     bool do_expensive_check);

template void ms_bfs(raft::handle_t const &handle,
                     graph_view_t<int32_t, int64_t, float, false, false> const &graph_view,
                     int32_t *distances,
                     int32_t *predecessors,
                     int32_t *sources,
                     size_t n_sources,
                     bool direction_optimizing,
                     int32_t depth_limit,
                     bool do_expensive_check);

template void ms_bfs(raft::handle_t const &handle,
                     graph_view_t<int32_t, int64_t, double, false, false> const &graph_view,
                     int32_t *distances,
                     int32_t *predecessors,
                     int32_t *sources,
                     size_t n_sources,
                     bool direction_optimizing,
                     int32_t depth_limit,
                     bool do_expensive_check);

template void ms_bfs(raft::handle_t const &handle,
                     graph_view_t<int64_t, int64_t, float, false, false> const &graph_view,
                     int64_t *distances,
                     int64_t *predecessors,
                     int64_t *sources,
                     size_t n_sources,
                     bool direction_optimizing,
                     int64_t depth_limit,
                     bool do_expensive_check);

template void ms_bfs(raft::handle_t const &handle,
                     graph_view_t<int64_t, int64_t, double, false, false> const &graph_view,
                     int64_t *distances,
                     int64_t *predecessors,
                     int64_t *sources,
                     size_t n_sources,
                     bool direction_optimizing,
                     int64_t depth_limit,
                     bool do_expensive_check);

}  // namespace experimental
}  // namespace cugraph
