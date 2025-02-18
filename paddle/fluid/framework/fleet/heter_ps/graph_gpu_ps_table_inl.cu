// Copyright (c) 2022 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <thrust/device_vector.h>
#include <thrust/reduce.h>
#include <thrust/scan.h>
#include <functional>
#include "cub/cub.cuh"
#pragma once
#ifdef PADDLE_WITH_HETERPS
#include "paddle/fluid/framework/fleet/heter_ps/gpu_graph_utils.h"
#include "paddle/fluid/framework/fleet/heter_ps/graph_gpu_ps_table.h"
namespace paddle {
namespace framework {
/*
comment 0
this kernel just serves as an example of how to sample nodes' neighbors.
feel free to modify it
index[0,len) saves the nodes' index
actual_size[0,len) is to save the sample size of each node.
for ith node in index, actual_size[i] = min(node i's neighbor size, sample size)
sample_result is to save the neighbor sampling result, its size is len *
sample_size;
*/

__global__ void get_cpu_id_index(uint64_t* key,
                                 int* actual_sample_size,
                                 uint64_t* cpu_key,
                                 int* sum,
                                 int* index,
                                 int len) {
  CUDA_KERNEL_LOOP(i, len) {
    if (actual_sample_size[i] == -1) {
      int old = atomicAdd(sum, 1);
      cpu_key[old] = key[i];
      index[old] = i;
      // printf("old %d i-%d key:%lld\n",old,i,key[i]);
    }
  }
}

__global__ void get_actual_gpu_ac(int* gpu_ac, int number_on_cpu) {
  CUDA_KERNEL_LOOP(i, number_on_cpu) { gpu_ac[i] /= sizeof(uint64_t); }
}

template <int WARP_SIZE, int BLOCK_WARPS, int TILE_SIZE>
__global__ void copy_buffer_ac_to_final_place(uint64_t* gpu_buffer,
                                              int* gpu_ac,
                                              uint64_t* val,
                                              int* actual_sample_size,
                                              int* index,
                                              int* cumsum_gpu_ac,
                                              int number_on_cpu,
                                              int sample_size) {
  assert(blockDim.x == WARP_SIZE);
  assert(blockDim.y == BLOCK_WARPS);

  int i = blockIdx.x * TILE_SIZE + threadIdx.y;
  const int last_idx =
      min(static_cast<int>(blockIdx.x + 1) * TILE_SIZE, number_on_cpu);
  while (i < last_idx) {
    actual_sample_size[index[i]] = gpu_ac[i];
    for (int j = threadIdx.x; j < gpu_ac[i]; j += WARP_SIZE) {
      val[index[i] * sample_size + j] = gpu_buffer[cumsum_gpu_ac[i] + j];
    }
    i += BLOCK_WARPS;
  }
}

__global__ void get_features_size(GpuPsFeaInfo* fea_info_array,
                                  uint32_t* feature_size,
                                  int n) {
  int idx = blockIdx.x * blockDim.y + threadIdx.y;
  if (idx < n) {
    feature_size[idx] = fea_info_array[idx].feature_size;
  }
}

__global__ void get_features_kernel(GpuPsCommGraphFea graph,
                                    GpuPsFeaInfo* fea_info_array,
                                    uint32_t* fea_size_prefix_sum,
                                    uint64_t* feature_array,
                                    uint8_t* slot_array,
                                    int n) {
  int idx = blockIdx.x * blockDim.y + threadIdx.y;
  if (idx < n) {
    uint32_t feature_size = fea_info_array[idx].feature_size;
    if (feature_size == 0) {
      return;
    }
    uint32_t src_offset = fea_info_array[idx].feature_offset;
    uint32_t dst_offset = fea_size_prefix_sum[idx];
    for (uint32_t j = 0; j < feature_size; ++j) {
      feature_array[dst_offset + j] = graph.feature_list[src_offset + j];
      slot_array[dst_offset + j] = graph.slot_id_list[src_offset + j];
    }
  }
}

__global__ void get_features_kernel(GpuPsCommGraphFea graph,
                                    GpuPsFeaInfo* fea_info_array,
                                    int* actual_size,
                                    uint64_t* feature,
                                    int* slot_feature_num_map,
                                    int slot_num,
                                    int n,
                                    int fea_num_per_node) {
  int idx = blockIdx.x * blockDim.y + threadIdx.y;
  if (idx < n) {
    int feature_size = fea_info_array[idx].feature_size;
    int src_offset = fea_info_array[idx].feature_offset;
    int dst_offset = idx * fea_num_per_node;
    uint64_t* dst_feature = &feature[dst_offset];
    if (feature_size == 0) {
      for (int k = 0; k < fea_num_per_node; ++k) {
        dst_feature[k] = 0;
      }
      actual_size[idx] = fea_num_per_node;
      return;
    }

    uint64_t* feature_start = &(graph.feature_list[src_offset]);
    uint8_t* slot_id_start = &(graph.slot_id_list[src_offset]);
    for (int slot_id = 0, dst_fea_idx = 0, src_fea_idx = 0; slot_id < slot_num;
         slot_id++) {
      int feature_num = slot_feature_num_map[slot_id];
      if (src_fea_idx >= feature_size || slot_id < slot_id_start[src_fea_idx]) {
        for (int j = 0; j < feature_num; ++j, ++dst_fea_idx) {
          dst_feature[dst_fea_idx] = 0;
        }
      } else if (slot_id == slot_id_start[src_fea_idx]) {
        for (int j = 0; j < feature_num; ++j, ++dst_fea_idx) {
          if (slot_id == slot_id_start[src_fea_idx]) {
            dst_feature[dst_fea_idx] = feature_start[src_fea_idx++];
          } else {
            dst_feature[dst_fea_idx] = 0;
          }
        }
      } else {
        assert(0);
      }
    }
    actual_size[idx] = fea_num_per_node;
  }
}

__global__ void get_node_degree_kernel(GpuPsNodeInfo* node_info_list,
                                       int* node_degree,
                                       int n) {
  const size_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) {
    node_degree[i] = node_info_list[i].neighbor_size;
  }
}

template <int WARP_SIZE, int BLOCK_WARPS, int TILE_SIZE>
__global__ void neighbor_sample_kernel_walking(GpuPsCommGraph graph,
                                               GpuPsNodeInfo* node_info_list,
                                               int* actual_size,
                                               uint64_t* res,
                                               int sample_len,
                                               int n,
                                               int default_value) {
  // graph: The corresponding edge table.
  // node_info_list: The input node query, duplicate nodes allowed.
  // actual_size: The actual sample size of the input nodes.
  // res: The output sample neighbors of the input nodes.
  // sample_len: The fix sample size.
  assert(blockDim.x == WARP_SIZE);
  assert(blockDim.y == BLOCK_WARPS);

  int i = blockIdx.x * TILE_SIZE + threadIdx.y;
  const int last_idx = min(static_cast<int>(blockIdx.x + 1) * TILE_SIZE, n);
  curandState rng;
  curand_init(blockIdx.x, threadIdx.y * WARP_SIZE + threadIdx.x, 0, &rng);
  while (i < last_idx) {
    if (node_info_list[i].neighbor_size == 0) {
      actual_size[i] = default_value;
      i += BLOCK_WARPS;
      continue;
    }
    int neighbor_len = node_info_list[i].neighbor_size;
    uint32_t data_offset = node_info_list[i].neighbor_offset;
    int offset = i * sample_len;
    uint64_t* data = graph.neighbor_list;
    if (neighbor_len <= sample_len) {
      for (int j = threadIdx.x; j < neighbor_len; j += WARP_SIZE) {
        res[offset + j] = data[data_offset + j];
      }
      actual_size[i] = neighbor_len;
    } else {
      for (int j = threadIdx.x; j < sample_len; j += WARP_SIZE) {
        res[offset + j] = j;
      }
      __syncwarp();
      for (int j = sample_len + threadIdx.x; j < neighbor_len; j += WARP_SIZE) {
        const int num = curand(&rng) % (j + 1);
        if (num < sample_len) {
          atomicMax(reinterpret_cast<unsigned int*>(res + offset + num),
                    static_cast<unsigned int>(j));
        }
      }
      __syncwarp();
      for (int j = threadIdx.x; j < sample_len; j += WARP_SIZE) {
        const int64_t perm_idx = res[offset + j] + data_offset;
        res[offset + j] = data[perm_idx];
      }
      actual_size[i] = sample_len;
    }
    i += BLOCK_WARPS;
  }
}

__global__ void neighbor_sample_kernel_all_edge_type(
    GpuPsCommGraph* graphs,
    GpuPsNodeInfo* node_info_base,
    int* actual_size_base,
    uint64_t* sample_array_base,
    int sample_len,
    int n,  // edge_type * shard_len
    int default_value,
    int shard_len) {
  // graph: All edge tables.
  // node_info_list: The input node query, must be unique, otherwise the
  // randomness gets worse. actual_size_base: The begin position of actual
  // sample size of the input nodes. sample_array_base: The begin position of
  // sample neighbors of the input nodes. sample_len: The fix sample size.
  curandState rng;
  curand_init(blockIdx.x, threadIdx.x, 0, &rng);
  const size_t i = blockIdx.x * blockDim.x + threadIdx.x;

  if (i < n) {
    int edge_idx = i / shard_len, node_i = i % shard_len;

    GpuPsNodeInfo* node_info_list = node_info_base + edge_idx * shard_len;
    int* actual_size_array = actual_size_base + edge_idx * shard_len;

    if (node_info_list[node_i].neighbor_size == 0) {
      actual_size_array[node_i] = default_value;
    } else {
      uint64_t* sample_array =
          sample_array_base + edge_idx * shard_len * sample_len;
      int neighbor_len = node_info_list[node_i].neighbor_size;
      uint32_t data_offset = node_info_list[node_i].neighbor_offset;
      int offset = node_i * sample_len;
      uint64_t* data = graphs[edge_idx].neighbor_list;
      uint64_t tmp;
      int split, begin;
      if (neighbor_len <= sample_len) {
        actual_size_array[node_i] = neighbor_len;
        for (int j = 0; j < neighbor_len; j++) {
          sample_array[offset + j] = data[data_offset + j];
        }
      } else {
        actual_size_array[node_i] = sample_len;
        if (neighbor_len < 2 * sample_len) {
          split = sample_len;
          begin = 0;
        } else {
          split = neighbor_len - sample_len;
          begin = neighbor_len - sample_len;
        }
        for (int idx = split; idx <= neighbor_len - 1; idx++) {
          const int num = curand(&rng) % (idx + 1);
          data[data_offset + idx] = atomicExch(
              reinterpret_cast<unsigned long long int*>(data +  // NOLINT
                                                        data_offset + num),
              static_cast<unsigned long long int>(  // NOLINT
                  data[data_offset + idx]));
        }
        for (int idx = 0; idx < sample_len; idx++) {
          sample_array[offset + idx] = data[data_offset + begin + idx];
        }
      }
    }
  }
}

int GpuPsGraphTable::init_cpu_table(
    const paddle::distributed::GraphParameter& graph, int gpu_num) {
  cpu_graph_table_.reset(new paddle::distributed::GraphTable);
  cpu_table_status = cpu_graph_table_->Initialize(graph);
  cpu_graph_table_->init_worker_poll(gpu_num);
  // if (cpu_table_status != 0) return cpu_table_status;
  // std::function<void(std::vector<GpuPsCommGraph>&)> callback =
  //     [this](std::vector<GpuPsCommGraph>& res) {
  //       pthread_rwlock_wrlock(this->rw_lock.get());
  //       this->clear_graph_info();
  //       this->build_graph_from_cpu(res);
  //       pthread_rwlock_unlock(this->rw_lock.get());
  //       cv_.notify_one();
  //     };
  // cpu_graph_table->set_graph_sample_callback(callback);
  return cpu_table_status;
}

/*
 comment 1
 gpu i triggers a neighbor_sample task,
 when this task is done,
 this function is called to move the sample result on other gpu back
 to gup i and aggragate the result.
 the sample_result is saved on src_sample_res and the actual sample size for
 each node is saved on actual_sample_size.
 the number of actual sample_result for
 key[x] (refer to comment 2 for definition of key)
 is saved on  actual_sample_size[x], since the neighbor size of key[x] might be
 smaller than sample_size,
 is saved on src_sample_res [x*sample_size, x*sample_size +
 actual_sample_size[x])
 since before each gpu runs the neighbor_sample task,the key array is shuffled,
 but we have the idx array to save the original order.
 when the gpu i gets all the sample results from other gpus, it relies on
 idx array to recover the original order.
 that's what fill_dvals does.
*/

void GpuPsGraphTable::display_sample_res(void* key,
                                         void* val,
                                         int len,
                                         int sample_len) {
  char key_buffer[len * sizeof(uint64_t)];  // NOLINT
  char val_buffer[sample_len * sizeof(int64_t) * len +
                  (len + len % 2) * sizeof(int) + len * sizeof(uint64_t)];
  cudaMemcpy(key_buffer, key, sizeof(uint64_t) * len, cudaMemcpyDeviceToHost);
  cudaMemcpy(val_buffer,
             val,
             sample_len * sizeof(int64_t) * len +
                 (len + len % 2) * sizeof(int) + len * sizeof(uint64_t),
             cudaMemcpyDeviceToHost);
  uint64_t* sample_val = reinterpret_cast<uint64_t*>(
      val_buffer + (len + len % 2) * sizeof(int) + len * sizeof(int64_t));
  for (int i = 0; i < len; i++) {
    printf("key %llu\n",
           *reinterpret_cast<int64_t*>(key_buffer + i * sizeof(uint64_t)));
    printf("index %llu\n",
           *reinterpret_cast<int64_t*>(val_buffer + i * sizeof(uint64_t)));
    int ac_size = *reinterpret_cast<int*>(val_buffer + i * sizeof(int) +
                                          len * sizeof(int64_t));
    printf("sampled %d neigbhors\n", ac_size);
    for (int j = 0; j < ac_size; j++) {
      printf("%llu ", sample_val[i * sample_len + j]);
    }
    printf("\n");
  }
}

void GpuPsGraphTable::move_result_to_source_gpu(int start_index,
                                                int gpu_num,
                                                int* h_left,
                                                int* h_right,
                                                int* fea_left,
                                                uint32_t* fea_num_list,
                                                uint32_t* actual_feature_size,
                                                uint64_t* feature_list,
                                                uint8_t* slot_list) {
  int shard_len[gpu_num];  // NOLINT
  for (int i = 0; i < gpu_num; i++) {
    if (h_left[i] == -1 || h_right[i] == -1) {
      continue;
    }
    shard_len[i] = h_right[i] - h_left[i] + 1;
    int cur_step = path_[start_index][i].nodes_.size() - 1;
    for (int j = cur_step; j > 0; j--) {
      CUDA_CHECK(
          cudaMemcpyAsync(path_[start_index][i].nodes_[j - 1].val_storage,
                          path_[start_index][i].nodes_[j].val_storage,
                          path_[start_index][i].nodes_[j - 1].val_bytes_len,
                          cudaMemcpyDefault,
                          path_[start_index][i].nodes_[j - 1].out_stream));
    }
    auto& node = path_[start_index][i].nodes_.front();

    if (fea_num_list[i] > 0) {
      CUDA_CHECK(cudaMemcpyAsync(
          reinterpret_cast<char*>(feature_list + fea_left[i]),
          node.val_storage +
              sizeof(uint32_t) * (shard_len[i] + shard_len[i] % 2),
          sizeof(uint64_t) * fea_num_list[i],
          cudaMemcpyDefault,
          node.out_stream));
      CUDA_CHECK(cudaMemcpyAsync(
          reinterpret_cast<char*>(slot_list + fea_left[i]),
          node.val_storage +
              sizeof(uint32_t) * (shard_len[i] + shard_len[i] % 2) +
              sizeof(uint64_t) * fea_num_list[i],
          sizeof(uint8_t) * fea_num_list[i],
          cudaMemcpyDefault,
          node.out_stream));
    }
    if (shard_len[i] > 0) {
      CUDA_CHECK(cudaMemcpyAsync(
          reinterpret_cast<char*>(actual_feature_size + h_left[i]),
          node.val_storage,
          sizeof(uint32_t) * shard_len[i],
          cudaMemcpyDefault,
          node.out_stream));
    }
  }
  for (int i = 0; i < gpu_num; ++i) {
    if (h_left[i] == -1 || h_right[i] == -1) {
      continue;
    }
    auto& node = path_[start_index][i].nodes_.front();
    CUDA_CHECK(cudaStreamSynchronize(node.out_stream));
  }
}

void GpuPsGraphTable::move_result_to_source_gpu(int start_index,
                                                int gpu_num,
                                                int sample_size,
                                                int* h_left,
                                                int* h_right,
                                                uint64_t* src_sample_res,
                                                int* actual_sample_size) {
  int shard_len[gpu_num];  // NOLINT
  for (int i = 0; i < gpu_num; i++) {
    if (h_left[i] == -1 || h_right[i] == -1) {
      continue;
    }
    shard_len[i] = h_right[i] - h_left[i] + 1;
    int cur_step = path_[start_index][i].nodes_.size() - 1;
    for (int j = cur_step; j > 0; j--) {
      CUDA_CHECK(
          cudaMemcpyAsync(path_[start_index][i].nodes_[j - 1].val_storage,
                          path_[start_index][i].nodes_[j].val_storage,
                          path_[start_index][i].nodes_[j - 1].val_bytes_len,
                          cudaMemcpyDefault,
                          path_[start_index][i].nodes_[j - 1].out_stream));
    }
    auto& node = path_[start_index][i].nodes_.front();
    CUDA_CHECK(cudaMemcpyAsync(
        reinterpret_cast<char*>(src_sample_res + h_left[i] * sample_size),
        node.val_storage + sizeof(int64_t) * shard_len[i] +
            sizeof(int) * (shard_len[i] + shard_len[i] % 2),
        sizeof(uint64_t) * shard_len[i] * sample_size,
        cudaMemcpyDefault,
        node.out_stream));
    CUDA_CHECK(
        cudaMemcpyAsync(reinterpret_cast<char*>(actual_sample_size + h_left[i]),
                        node.val_storage + sizeof(int64_t) * shard_len[i],
                        sizeof(int) * shard_len[i],
                        cudaMemcpyDefault,
                        node.out_stream));
  }
  for (int i = 0; i < gpu_num; ++i) {
    if (h_left[i] == -1 || h_right[i] == -1) {
      continue;
    }
    auto& node = path_[start_index][i].nodes_.front();
    CUDA_CHECK(cudaStreamSynchronize(node.out_stream));
    // cudaStreamSynchronize(resource_->remote_stream(i, start_index));
  }
}

void GpuPsGraphTable::move_degree_to_source_gpu(
    int start_index, int gpu_num, int* h_left, int* h_right, int* node_degree) {
  int shard_len[gpu_num];
  for (int i = 0; i < gpu_num; i++) {
    if (h_left[i] == -1 || h_right[i] == -1) {
      continue;
    }
    shard_len[i] = h_right[i] - h_left[i] + 1;
    int cur_step = (int)path_[start_index][i].nodes_.size() - 1;
    for (int j = cur_step; j > 0; j--) {
      CUDA_CHECK(
          cudaMemcpyAsync(path_[start_index][i].nodes_[j - 1].val_storage,
                          path_[start_index][i].nodes_[j].val_storage,
                          path_[start_index][i].nodes_[j - 1].val_bytes_len,
                          cudaMemcpyDefault,
                          path_[start_index][i].nodes_[j - 1].out_stream));
    }
    auto& node = path_[start_index][i].nodes_.front();
    CUDA_CHECK(
        cudaMemcpyAsync(reinterpret_cast<char*>(node_degree + h_left[i]),
                        node.val_storage + sizeof(int64_t) * shard_len[i],
                        sizeof(int) * shard_len[i],
                        cudaMemcpyDefault,
                        node.out_stream));
  }

  for (int i = 0; i < gpu_num; ++i) {
    if (h_left[i] == -1 || h_right[i] == -1) {
      continue;
    }
    auto& node = path_[start_index][i].nodes_.front();
    CUDA_CHECK(cudaStreamSynchronize(node.out_stream));
  }
}

void GpuPsGraphTable::move_result_to_source_gpu_all_edge_type(
    int start_index,
    int gpu_num,
    int sample_size,
    int* h_left,
    int* h_right,
    uint64_t* src_sample_res,
    int* actual_sample_size,
    int edge_type_len,
    int len) {
  int shard_len[gpu_num];  // NOLINT

  for (int i = 0; i < gpu_num; i++) {
    if (h_left[i] == -1 || h_right[i] == -1) {
      continue;
    }
    shard_len[i] = h_right[i] - h_left[i] + 1;
    int cur_step = path_[start_index][i].nodes_.size() - 1;
    for (int j = cur_step; j > 0; j--) {
      CUDA_CHECK(
          cudaMemcpyAsync(path_[start_index][i].nodes_[j - 1].val_storage,
                          path_[start_index][i].nodes_[j].val_storage,
                          path_[start_index][i].nodes_[j - 1].val_bytes_len,
                          cudaMemcpyDefault,
                          path_[start_index][i].nodes_[j - 1].out_stream));
    }
  }

  for (int i = 0; i < edge_type_len; i++) {
    for (int j = 0; j < gpu_num; j++) {
      if (h_left[j] == -1 || h_right[j] == -1) {
        continue;
      }
      auto& node = path_[start_index][j].nodes_.front();
      CUDA_CHECK(cudaMemcpyAsync(
          reinterpret_cast<char*>(src_sample_res + i * len * sample_size +
                                  h_left[j] * sample_size),
          node.val_storage + sizeof(int64_t) * shard_len[j] * edge_type_len +
              sizeof(int) * (shard_len[j] * edge_type_len +
                             (shard_len[j] * edge_type_len) % 2) +
              sizeof(uint64_t) * i * shard_len[j] * sample_size,
          sizeof(uint64_t) * shard_len[j] * sample_size,
          cudaMemcpyDefault,
          node.out_stream));
      CUDA_CHECK(cudaMemcpyAsync(
          reinterpret_cast<char*>(actual_sample_size + i * len + h_left[j]),
          node.val_storage + sizeof(int64_t) * shard_len[j] * edge_type_len +
              sizeof(int) * i * shard_len[j],
          sizeof(int) * shard_len[j],
          cudaMemcpyDefault,
          node.out_stream));
    }
  }

  for (int i = 0; i < gpu_num; i++) {
    if (h_left[i] == -1 || h_right[i] == -1) {
      continue;
    }
    auto& node = path_[start_index][i].nodes_.front();
    CUDA_CHECK(cudaStreamSynchronize(node.out_stream));
  }
}

__global__ void fill_size(uint32_t* d_actual_size_list,
                          uint32_t* d_shard_size_list,
                          int* idx,
                          int len) {
  const size_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < len) {
    d_actual_size_list[idx[i]] = d_shard_size_list[i];
  }
}

__global__ void fill_feature_and_slot(uint64_t* dst_feature_list,
                                      uint8_t* dst_slot_list,
                                      uint32_t* dst_size_prefix_sum_list,
                                      uint64_t* src_feature_list,
                                      uint8_t* src_slot_list,
                                      uint32_t* src_size_prefix_sum_list,
                                      uint32_t* src_size_list,
                                      int* idx,
                                      int len) {
  const size_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < len) {
    uint32_t dst_index = dst_size_prefix_sum_list[idx[i]];
    uint32_t src_index = src_size_prefix_sum_list[i];
    for (uint32_t j = 0; j < src_size_list[i]; j++) {
      dst_feature_list[dst_index + j] = src_feature_list[src_index + j];
      dst_slot_list[dst_index + j] = src_slot_list[src_index + j];
    }
  }
}

/*
TODO:
how to optimize it to eliminate the for loop
*/
__global__ void fill_dvalues(uint64_t* d_shard_vals,
                             uint64_t* d_vals,
                             int* d_shard_actual_sample_size,
                             int* d_actual_sample_size,
                             int* idx,
                             int sample_size,
                             int len) {
  const size_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < len) {
    d_actual_sample_size[idx[i]] = d_shard_actual_sample_size[i];
    size_t offset1 = idx[i] * sample_size;
    size_t offset2 = i * sample_size;
    for (int j = 0; j < d_shard_actual_sample_size[i]; j++) {
      d_vals[offset1 + j] = d_shard_vals[offset2 + j];
    }
  }
}

__global__ void fill_dvalues(int* d_shard_degree,
                             int* d_degree,
                             int* idx,
                             int len) {
  const size_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < len) {
    d_degree[idx[i]] = d_shard_degree[i];
  }
}

__global__ void fill_dvalues_with_edge_type(uint64_t* d_shard_vals,
                                            uint64_t* d_vals,
                                            int* d_shard_actual_sample_size,
                                            int* d_actual_sample_size,
                                            int* idx,
                                            int sample_size,
                                            int len,    // len * edge_type_len
                                            int mod) {  // len
  const size_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < len) {
    int a = i % mod, b = i - i % mod;
    d_actual_sample_size[b + idx[a]] = d_shard_actual_sample_size[i];
    size_t offset1 = (b + idx[a]) * sample_size;
    size_t offset2 = i * sample_size;
    for (int j = 0; j < d_shard_actual_sample_size[i]; j++) {
      d_vals[offset1 + j] = d_shard_vals[offset2 + j];
    }
  }
}

__global__ void fill_dvalues(uint64_t* d_shard_vals,
                             uint64_t* d_vals,
                             int* d_shard_actual_sample_size,
                             int* idx,
                             int sample_size,
                             int len) {
  const size_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < len) {
    for (int j = 0; j < sample_size; j++) {
      d_vals[idx[i] * sample_size + j] = d_shard_vals[i * sample_size + j];
    }
  }
}

__global__ void fill_actual_vals(uint64_t* vals,
                                 uint64_t* actual_vals,
                                 int* actual_sample_size,
                                 int* cumsum_actual_sample_size,
                                 int sample_size,
                                 int len) {
  const size_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < len) {
    int offset1 = cumsum_actual_sample_size[i];
    int offset2 = sample_size * i;
    for (int j = 0; j < actual_sample_size[i]; j++) {
      actual_vals[offset1 + j] = vals[offset2 + j];
    }
  }
}

__global__ void node_query_example(GpuPsCommGraph graph,
                                   int start,
                                   int size,
                                   uint64_t* res) {
  const size_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < size) {
    res[i] = graph.node_list[start + i];
  }
}

void GpuPsGraphTable::clear_feature_info(int gpu_id) {
  int idx = 0;
  int offset = get_table_offset(gpu_id, GraphTableType::FEATURE_TABLE, idx);
  if (offset < tables_.size()) {
    delete tables_[offset];
    tables_[offset] = NULL;
  }

  int graph_fea_idx = get_graph_fea_list_offset(gpu_id);
  auto& graph = gpu_graph_fea_list_[graph_fea_idx];
  if (graph.feature_list != NULL) {
    cudaFree(graph.feature_list);
    graph.feature_list = NULL;
  }

  if (graph.slot_id_list != NULL) {
    cudaFree(graph.slot_id_list);
    graph.slot_id_list = NULL;
  }
  graph.feature_capacity = 0;
}

void GpuPsGraphTable::reset_feature_info(int gpu_id,
                                         size_t capacity,
                                         size_t feature_size) {
  int idx = 0;
  int offset = get_table_offset(gpu_id, GraphTableType::FEATURE_TABLE, idx);
  if (offset < tables_.size()) {
    delete tables_[offset];
    tables_[offset] = new Table(capacity);
  }
  int graph_fea_idx = get_graph_fea_list_offset(gpu_id);
  auto& graph = gpu_graph_fea_list_[graph_fea_idx];
  graph.node_list = NULL;
  if (graph.feature_list == NULL) {
    CUDA_CHECK(
        cudaMalloc(&graph.feature_list, feature_size * sizeof(uint64_t)));
    CUDA_CHECK(cudaMalloc(&graph.slot_id_list, feature_size * sizeof(uint8_t)));
    graph.feature_capacity = feature_size;
  } else if (graph.feature_capacity < feature_size) {
    cudaFree(graph.feature_list);
    cudaFree(graph.slot_id_list);
    CUDA_CHECK(
        cudaMalloc(&graph.feature_list, feature_size * sizeof(uint64_t)));
    CUDA_CHECK(cudaMalloc(&graph.slot_id_list, feature_size * sizeof(uint8_t)));
    graph.feature_capacity = feature_size;
  } else {
    CUDA_CHECK(
        cudaMemset(graph.feature_list, 0, feature_size * sizeof(uint64_t)));
    CUDA_CHECK(
        cudaMemset(graph.slot_id_list, 0, feature_size * sizeof(uint8_t)));
  }
}

void GpuPsGraphTable::clear_graph_info(int gpu_id, int idx) {
  if (idx >= graph_table_num_) return;
  int offset = get_table_offset(gpu_id, GraphTableType::EDGE_TABLE, idx);
  if (offset < tables_.size()) {
    delete tables_[offset];
    tables_[offset] = NULL;
  }
  auto& graph = gpu_graph_list_[get_graph_list_offset(gpu_id, idx)];
  if (graph.neighbor_list != NULL) {
    cudaFree(graph.neighbor_list);
    graph.neighbor_list = nullptr;
  }
  if (graph.node_list != NULL) {
    cudaFree(graph.node_list);
    graph.node_list = nullptr;
  }
}
void GpuPsGraphTable::clear_graph_info(int idx) {
  for (int i = 0; i < gpu_num; i++) clear_graph_info(i, idx);
}
/*
the parameter std::vector<GpuPsCommGraph> cpu_graph_list is generated by cpu.
it saves the graph to be saved on each gpu.
for the ith GpuPsCommGraph, any the node's key satisfies that key % gpu_number
== i
In this function, memory is allocated on each gpu to save the graphs,
gpu i saves the ith graph from cpu_graph_list
*/
void GpuPsGraphTable::build_graph_fea_on_single_gpu(const GpuPsCommGraphFea& g,
                                                    int gpu_id) {
  platform::CUDADeviceGuard guard(resource_->dev_id(gpu_id));
  size_t capacity = std::max((uint64_t)1, g.node_size) / load_factor_;
  reset_feature_info(gpu_id, capacity, g.feature_size);
  int ntype_id = 0;
  int offset = get_graph_fea_list_offset(gpu_id);
  int table_offset =
      get_table_offset(gpu_id, GraphTableType::FEATURE_TABLE, ntype_id);
  if (g.node_size > 0) {
    build_ps(gpu_id,
             g.node_list,
             reinterpret_cast<uint64_t*>(g.fea_info_list),
             g.node_size,
             1024,
             8,
             table_offset);
    gpu_graph_fea_list_[offset].node_size = g.node_size;
  } else {
    build_ps(gpu_id, NULL, NULL, 0, 1024, 8, table_offset);
    gpu_graph_fea_list_[offset].node_size = 0;
  }
  if (g.feature_size) {
    CUDA_CHECK(cudaMemcpy(gpu_graph_fea_list_[offset].feature_list,
                          g.feature_list,
                          g.feature_size * sizeof(uint64_t),
                          cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(gpu_graph_fea_list_[offset].slot_id_list,
                          g.slot_id_list,
                          g.feature_size * sizeof(uint8_t),
                          cudaMemcpyHostToDevice));

    gpu_graph_fea_list_[offset].feature_size = g.feature_size;
  } else {
    gpu_graph_fea_list_[offset].feature_size = 0;
  }
  VLOG(1) << "gpu node_feature info card :" << gpu_id << " ,node_size is "
          << gpu_graph_fea_list_[offset].node_size << ", feature_size is "
          << gpu_graph_fea_list_[offset].feature_size;
}

std::vector<std::shared_ptr<phi::Allocation>>
GpuPsGraphTable::get_edge_type_graph(int gpu_id, int edge_type_len) {
  int total_gpu = resource_->total_device();
  auto stream = resource_->local_stream(gpu_id, 0);

  platform::CUDAPlace place = platform::CUDAPlace(resource_->dev_id(gpu_id));
  platform::CUDADeviceGuard guard(resource_->dev_id(gpu_id));

  std::vector<std::shared_ptr<phi::Allocation>> graphs_vec;
  for (int i = 0; i < total_gpu; i++) {
    GpuPsCommGraph graphs[edge_type_len];  // NOLINT
    for (int idx = 0; idx < edge_type_len; idx++) {
      int table_offset = get_table_offset(i, GraphTableType::EDGE_TABLE, idx);
      int offset = get_graph_list_offset(i, idx);
      graphs[idx] = gpu_graph_list_[offset];
    }
    auto d_commgraph_mem = memory::AllocShared(
        place,
        edge_type_len * sizeof(GpuPsCommGraph),
        phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
    GpuPsCommGraph* d_commgraph_ptr =
        reinterpret_cast<GpuPsCommGraph*>(d_commgraph_mem->ptr());
    CUDA_CHECK(cudaMemcpy(d_commgraph_ptr,
                          graphs,
                          sizeof(GpuPsCommGraph) * edge_type_len,
                          cudaMemcpyHostToDevice));
    graphs_vec.emplace_back(d_commgraph_mem);
  }

  return graphs_vec;
}

/*
the parameter std::vector<GpuPsCommGraph> cpu_graph_list is generated by cpu.
it saves the graph to be saved on each gpu.
for the ith GpuPsCommGraph, any the node's key satisfies that key % gpu_number
== i
In this function, memory is allocated on each gpu to save the graphs,
gpu i saves the ith graph from cpu_graph_list
*/
void GpuPsGraphTable::build_graph_on_single_gpu(const GpuPsCommGraph& g,
                                                int gpu_id,
                                                int edge_idx) {
  clear_graph_info(gpu_id, edge_idx);
  platform::CUDADeviceGuard guard(resource_->dev_id(gpu_id));
  int offset = get_graph_list_offset(gpu_id, edge_idx);
  gpu_graph_list_[offset] = GpuPsCommGraph();
  int table_offset =
      get_table_offset(gpu_id, GraphTableType::EDGE_TABLE, edge_idx);
  size_t capacity = std::max((uint64_t)1, (uint64_t)g.node_size) / load_factor_;
  tables_[table_offset] = new Table(capacity);
  if (g.node_size > 0) {
    if (FLAGS_gpugraph_load_node_list_into_hbm) {
      CUDA_CHECK(cudaMalloc(&gpu_graph_list_[offset].node_list,
                            g.node_size * sizeof(uint64_t)));
      CUDA_CHECK(cudaMemcpy(gpu_graph_list_[offset].node_list,
                            g.node_list,
                            g.node_size * sizeof(uint64_t),
                            cudaMemcpyHostToDevice));
    }

    build_ps(gpu_id,
             g.node_list,
             reinterpret_cast<uint64_t*>(g.node_info_list),
             g.node_size,
             1024,
             8,
             table_offset);
    gpu_graph_list_[offset].node_size = g.node_size;
  } else {
    build_ps(gpu_id, NULL, NULL, 0, 1024, 8, table_offset);
    gpu_graph_list_[offset].node_list = NULL;
    gpu_graph_list_[offset].node_size = 0;
  }
  if (g.neighbor_size) {
    cudaError_t cudaStatus = cudaMalloc(&gpu_graph_list_[offset].neighbor_list,
                                        g.neighbor_size * sizeof(uint64_t));
    PADDLE_ENFORCE_EQ(cudaStatus,
                      cudaSuccess,
                      platform::errors::InvalidArgument(
                          "ailed to allocate memory for graph on gpu "));
    VLOG(0) << "sucessfully allocate " << g.neighbor_size * sizeof(uint64_t)
            << " bytes of memory for graph-edges on gpu "
            << resource_->dev_id(gpu_id);
    CUDA_CHECK(cudaMemcpy(gpu_graph_list_[offset].neighbor_list,
                          g.neighbor_list,
                          g.neighbor_size * sizeof(uint64_t),
                          cudaMemcpyHostToDevice));
    gpu_graph_list_[offset].neighbor_size = g.neighbor_size;
  } else {
    gpu_graph_list_[offset].neighbor_list = NULL;
    gpu_graph_list_[offset].neighbor_size = 0;
  }
  VLOG(0) << " gpu node_neighbor info card: " << gpu_id << " ,node_size is "
          << gpu_graph_list_[offset].node_size << ", neighbor_size is "
          << gpu_graph_list_[offset].neighbor_size;
}

void GpuPsGraphTable::build_graph_from_cpu(
    const std::vector<GpuPsCommGraph>& cpu_graph_list, int edge_idx) {
  VLOG(0) << "in build_graph_from_cpu cpu_graph_list size = "
          << cpu_graph_list.size();
  PADDLE_ENFORCE_EQ(
      cpu_graph_list.size(),
      resource_->total_device(),
      platform::errors::InvalidArgument("the cpu node list size doesn't match "
                                        "the number of gpu on your machine."));
  clear_graph_info(edge_idx);
  for (int i = 0; i < cpu_graph_list.size(); i++) {
    int table_offset =
        get_table_offset(i, GraphTableType::EDGE_TABLE, edge_idx);
    int offset = get_graph_list_offset(i, edge_idx);
    platform::CUDADeviceGuard guard(resource_->dev_id(i));
    gpu_graph_list_[offset] = GpuPsCommGraph();
    tables_[table_offset] =
        new Table(std::max((uint64_t)1, (uint64_t)cpu_graph_list[i].node_size) /
                  load_factor_);
    if (cpu_graph_list[i].node_size > 0) {
      CUDA_CHECK(cudaMalloc(&gpu_graph_list_[offset].node_list,
                            cpu_graph_list[i].node_size * sizeof(uint64_t)));
      CUDA_CHECK(cudaMemcpy(gpu_graph_list_[offset].node_list,
                            cpu_graph_list[i].node_list,
                            cpu_graph_list[i].node_size * sizeof(uint64_t),
                            cudaMemcpyHostToDevice));
      build_ps(i,
               cpu_graph_list[i].node_list,
               reinterpret_cast<uint64_t*>(cpu_graph_list[i].node_info_list),
               cpu_graph_list[i].node_size,
               1024,
               8,
               table_offset);
      gpu_graph_list_[offset].node_size = cpu_graph_list[i].node_size;
    } else {
      build_ps(i, NULL, NULL, 0, 1024, 8, table_offset);
      gpu_graph_list_[offset].node_list = NULL;
      gpu_graph_list_[offset].node_size = 0;
    }
    if (cpu_graph_list[i].neighbor_size) {
      CUDA_CHECK(
          cudaMalloc(&gpu_graph_list_[offset].neighbor_list,
                     cpu_graph_list[i].neighbor_size * sizeof(uint64_t)));

      CUDA_CHECK(cudaMemcpy(gpu_graph_list_[offset].neighbor_list,
                            cpu_graph_list[i].neighbor_list,
                            cpu_graph_list[i].neighbor_size * sizeof(uint64_t),
                            cudaMemcpyHostToDevice));
      gpu_graph_list_[offset].neighbor_size = cpu_graph_list[i].neighbor_size;
    } else {
      gpu_graph_list_[offset].neighbor_list = NULL;
      gpu_graph_list_[offset].neighbor_size = 0;
    }
  }
  CUDA_CHECK(cudaDeviceSynchronize());
}

NeighborSampleResult GpuPsGraphTable::graph_neighbor_sample_v3(
    NeighborSampleQuery q, bool cpu_switch, bool compress = true) {
  return graph_neighbor_sample_v2(global_device_map[q.gpu_id],
                                  q.table_idx,
                                  q.src_nodes,
                                  q.sample_size,
                                  q.len,
                                  cpu_switch,
                                  compress);
}

NeighborSampleResult GpuPsGraphTable::graph_neighbor_sample(int gpu_id,
                                                            uint64_t* key,
                                                            int sample_size,
                                                            int len) {
  return graph_neighbor_sample_v2(
      gpu_id, 0, key, sample_size, len, false, true);
}

NeighborSampleResult GpuPsGraphTable::graph_neighbor_sample_v2(
    int gpu_id,
    int idx,
    uint64_t* key,
    int sample_size,
    int len,
    bool cpu_query_switch,
    bool compress) {
  NeighborSampleResult result;
  auto stream = resource_->local_stream(gpu_id, 0);
  result.set_stream(stream);
  result.initialize(sample_size, len, resource_->dev_id(gpu_id));

  if (len == 0) {
    return result;
  }

  platform::CUDAPlace place = platform::CUDAPlace(resource_->dev_id(gpu_id));
  platform::CUDADeviceGuard guard(resource_->dev_id(gpu_id));

  int* actual_sample_size = result.actual_sample_size;
  uint64_t* val = result.val;
  int total_gpu = resource_->total_device();

  int grid_size = (len - 1) / block_size_ + 1;

  int h_left[total_gpu];   // NOLINT
  int h_right[total_gpu];  // NOLINT

  auto d_left =
      memory::Alloc(place,
                    total_gpu * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  auto d_right =
      memory::Alloc(place,
                    total_gpu * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_left_ptr = reinterpret_cast<int*>(d_left->ptr());
  int* d_right_ptr = reinterpret_cast<int*>(d_right->ptr());
  int default_value = 0;
  if (cpu_query_switch) {
    default_value = -1;
  }

  CUDA_CHECK(cudaMemsetAsync(d_left_ptr, -1, total_gpu * sizeof(int), stream));
  CUDA_CHECK(cudaMemsetAsync(d_right_ptr, -1, total_gpu * sizeof(int), stream));
  //
  auto d_idx =
      memory::Alloc(place,
                    len * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_idx_ptr = reinterpret_cast<int*>(d_idx->ptr());

  auto d_shard_keys =
      memory::Alloc(place,
                    len * sizeof(uint64_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  uint64_t* d_shard_keys_ptr = reinterpret_cast<uint64_t*>(d_shard_keys->ptr());
  auto d_shard_vals =
      memory::Alloc(place,
                    sample_size * len * sizeof(uint64_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  uint64_t* d_shard_vals_ptr = reinterpret_cast<uint64_t*>(d_shard_vals->ptr());
  auto d_shard_actual_sample_size =
      memory::Alloc(place,
                    len * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_shard_actual_sample_size_ptr =
      reinterpret_cast<int*>(d_shard_actual_sample_size->ptr());

  split_input_to_shard(reinterpret_cast<uint64_t*>(key),
                       d_idx_ptr,
                       len,
                       d_left_ptr,
                       d_right_ptr,
                       gpu_id);

  heter_comm_kernel_->fill_shard_key(
      d_shard_keys_ptr, key, d_idx_ptr, len, stream);

  CUDA_CHECK(cudaStreamSynchronize(stream));

  CUDA_CHECK(cudaMemcpyAsync(h_left,
                             d_left_ptr,
                             total_gpu * sizeof(int),
                             cudaMemcpyDeviceToHost,
                             stream));
  CUDA_CHECK(cudaMemcpyAsync(h_right,
                             d_right_ptr,
                             total_gpu * sizeof(int),
                             cudaMemcpyDeviceToHost,
                             stream));
  CUDA_CHECK(cudaStreamSynchronize(stream));
  device_mutex_[gpu_id]->lock();
  for (int i = 0; i < total_gpu; ++i) {
    int shard_len = h_left[i] == -1 ? 0 : h_right[i] - h_left[i] + 1;
    if (shard_len == 0) {
      continue;
    }
    create_storage(gpu_id,
                   i,
                   shard_len * sizeof(uint64_t),
                   shard_len * sample_size * sizeof(uint64_t) +
                       shard_len * sizeof(uint64_t) +
                       sizeof(int) * (shard_len + shard_len % 2));
  }
  walk_to_dest(gpu_id,
               total_gpu,
               h_left,
               h_right,
               reinterpret_cast<uint64_t*>(d_shard_keys_ptr),
               NULL);

  for (int i = 0; i < total_gpu; ++i) {
    if (h_left[i] == -1) {
      continue;
    }
    int shard_len = h_left[i] == -1 ? 0 : h_right[i] - h_left[i] + 1;
    auto& node = path_[gpu_id][i].nodes_.back();

    CUDA_CHECK(cudaMemsetAsync(
        node.val_storage, 0, shard_len * sizeof(uint64_t), node.in_stream));
    CUDA_CHECK(cudaStreamSynchronize(node.in_stream));
    platform::CUDADeviceGuard guard(resource_->dev_id(i));
    // If not found, val is -1.
    int table_offset = get_table_offset(i, GraphTableType::EDGE_TABLE, idx);
    int offset = get_graph_list_offset(i, idx);
    tables_[table_offset]->get(reinterpret_cast<uint64_t*>(node.key_storage),
                               reinterpret_cast<uint64_t*>(node.val_storage),
                               static_cast<size_t>(h_right[i] - h_left[i] + 1),
                               resource_->remote_stream(i, gpu_id));

    auto graph = gpu_graph_list_[offset];
    GpuPsNodeInfo* node_info_list =
        reinterpret_cast<GpuPsNodeInfo*>(node.val_storage);
    int* actual_size_array = reinterpret_cast<int*>(node_info_list + shard_len);
    uint64_t* sample_array = reinterpret_cast<uint64_t*>(
        actual_size_array + shard_len + shard_len % 2);

    constexpr int WARP_SIZE = 32;
    constexpr int BLOCK_WARPS = 128 / WARP_SIZE;
    constexpr int TILE_SIZE = BLOCK_WARPS * 16;
    const dim3 block(WARP_SIZE, BLOCK_WARPS);
    const dim3 grid((shard_len + TILE_SIZE - 1) / TILE_SIZE);
    neighbor_sample_kernel_walking<WARP_SIZE, BLOCK_WARPS, TILE_SIZE>
        <<<grid, block, 0, resource_->remote_stream(i, gpu_id)>>>(
            graph,
            node_info_list,
            actual_size_array,
            sample_array,
            sample_size,
            shard_len,
            default_value);
  }

  for (int i = 0; i < total_gpu; ++i) {
    if (h_left[i] == -1) {
      continue;
    }
    CUDA_CHECK(cudaStreamSynchronize(resource_->remote_stream(i, gpu_id)));
  }
  move_result_to_source_gpu(gpu_id,
                            total_gpu,
                            sample_size,
                            h_left,
                            h_right,
                            d_shard_vals_ptr,
                            d_shard_actual_sample_size_ptr);

  for (int i = 0; i < total_gpu; ++i) {
    int shard_len = h_left[i] == -1 ? 0 : h_right[i] - h_left[i] + 1;
    if (shard_len == 0) {
      continue;
    }
    destroy_storage(gpu_id, i);
  }
  device_mutex_[gpu_id]->unlock();

  fill_dvalues<<<grid_size, block_size_, 0, stream>>>(
      d_shard_vals_ptr,
      val,
      d_shard_actual_sample_size_ptr,
      actual_sample_size,
      d_idx_ptr,
      sample_size,
      len);

  CUDA_CHECK(cudaStreamSynchronize(stream));

  if (cpu_query_switch) {
    // Get cpu keys and corresponding position.
    thrust::device_vector<uint64_t> t_cpu_keys(len);
    thrust::device_vector<int> t_index(len + 1, 0);
    get_cpu_id_index<<<grid_size, block_size_, 0, stream>>>(
        key,
        actual_sample_size,
        thrust::raw_pointer_cast(t_cpu_keys.data()),
        thrust::raw_pointer_cast(t_index.data()),
        thrust::raw_pointer_cast(t_index.data()) + 1,
        len);

    CUDA_CHECK(cudaStreamSynchronize(stream));

    int number_on_cpu = 0;
    CUDA_CHECK(cudaMemcpy(&number_on_cpu,
                          thrust::raw_pointer_cast(t_index.data()),
                          sizeof(int),
                          cudaMemcpyDeviceToHost));
    if (number_on_cpu > 0) {
      uint64_t* cpu_keys = new uint64_t[number_on_cpu];
      CUDA_CHECK(cudaMemcpy(cpu_keys,
                            thrust::raw_pointer_cast(t_cpu_keys.data()),
                            number_on_cpu * sizeof(uint64_t),
                            cudaMemcpyDeviceToHost));

      std::vector<std::shared_ptr<char>> buffers(number_on_cpu);
      std::vector<int> ac(number_on_cpu);

      auto status = cpu_graph_table_->random_sample_neighbors(
          idx, cpu_keys, sample_size, buffers, ac, false);

      int total_cpu_sample_size = std::accumulate(ac.begin(), ac.end(), 0);
      total_cpu_sample_size /= sizeof(uint64_t);

      // Merge buffers into one uint64_t vector.
      uint64_t* merge_buffers = new uint64_t[total_cpu_sample_size];
      int start = 0;
      for (int j = 0; j < number_on_cpu; j++) {
        memcpy(merge_buffers + start,
               reinterpret_cast<uint64_t*>(buffers[j].get()),
               ac[j]);
        start += ac[j] / sizeof(uint64_t);
      }

      // Copy merge_buffers to gpu.
      thrust::device_vector<uint64_t> gpu_buffers(total_cpu_sample_size);
      thrust::device_vector<int> gpu_ac(number_on_cpu);
      uint64_t* gpu_buffers_ptr = thrust::raw_pointer_cast(gpu_buffers.data());
      int* gpu_ac_ptr = thrust::raw_pointer_cast(gpu_ac.data());
      CUDA_CHECK(cudaMemcpyAsync(gpu_buffers_ptr,
                                 merge_buffers,
                                 total_cpu_sample_size * sizeof(uint64_t),
                                 cudaMemcpyHostToDevice,
                                 stream));
      CUDA_CHECK(cudaMemcpyAsync(gpu_ac_ptr,
                                 ac.data(),
                                 number_on_cpu * sizeof(int),
                                 cudaMemcpyHostToDevice,
                                 stream));

      // Copy gpu_buffers and gpu_ac using kernel.
      // Kernel divide for gpu_ac_ptr.
      int grid_size2 = (number_on_cpu - 1) / block_size_ + 1;
      get_actual_gpu_ac<<<grid_size2, block_size_, 0, stream>>>(gpu_ac_ptr,
                                                                number_on_cpu);

      CUDA_CHECK(cudaStreamSynchronize(stream));

      thrust::device_vector<int> cumsum_gpu_ac(number_on_cpu);
      thrust::exclusive_scan(
          gpu_ac.begin(), gpu_ac.end(), cumsum_gpu_ac.begin(), 0);

      constexpr int WARP_SIZE_ = 32;
      constexpr int BLOCK_WARPS_ = 128 / WARP_SIZE_;
      constexpr int TILE_SIZE_ = BLOCK_WARPS_ * 16;
      const dim3 block2(WARP_SIZE_, BLOCK_WARPS_);
      const dim3 grid2((number_on_cpu + TILE_SIZE_ - 1) / TILE_SIZE_);
      copy_buffer_ac_to_final_place<WARP_SIZE_, BLOCK_WARPS_, TILE_SIZE_>
          <<<grid2, block2, 0, stream>>>(
              gpu_buffers_ptr,
              gpu_ac_ptr,
              val,
              actual_sample_size,
              thrust::raw_pointer_cast(t_index.data()) + 1,
              thrust::raw_pointer_cast(cumsum_gpu_ac.data()),
              number_on_cpu,
              sample_size);

      delete[] merge_buffers;
      delete[] cpu_keys;
    }
    CUDA_CHECK(cudaStreamSynchronize(stream));
  }

  if (compress) {
    CUDA_CHECK(cudaStreamSynchronize(stream));
    platform::CUDAPlace place = platform::CUDAPlace(resource_->dev_id(gpu_id));
    platform::CUDADeviceGuard guard(resource_->dev_id(gpu_id));
    size_t temp_storage_bytes = 0;
    int total_sample_size = 0;
    auto cumsum_actual_sample_size =
        memory::Alloc(place,
                      (len + 1) * sizeof(int),
                      phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
    int* cumsum_actual_sample_size_p =
        reinterpret_cast<int*>(cumsum_actual_sample_size->ptr());
    CUDA_CHECK(
        cudaMemsetAsync(cumsum_actual_sample_size_p, 0, sizeof(int), stream));
    CUDA_CHECK(cub::DeviceScan::InclusiveSum(NULL,
                                             temp_storage_bytes,
                                             actual_sample_size,
                                             cumsum_actual_sample_size_p + 1,
                                             len,
                                             stream));
    auto d_temp_storage =
        memory::Alloc(place,
                      temp_storage_bytes,
                      phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
    CUDA_CHECK(cub::DeviceScan::InclusiveSum(d_temp_storage->ptr(),
                                             temp_storage_bytes,
                                             actual_sample_size,
                                             cumsum_actual_sample_size_p + 1,
                                             len,
                                             stream));
    CUDA_CHECK(cudaMemcpyAsync(&total_sample_size,
                               cumsum_actual_sample_size_p + len,
                               sizeof(int),
                               cudaMemcpyDeviceToHost,
                               stream));
    CUDA_CHECK(cudaStreamSynchronize(stream));
    result.actual_val_mem = memory::AllocShared(
        place,
        total_sample_size * sizeof(uint64_t),
        phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
    result.actual_val =
        reinterpret_cast<uint64_t*>((result.actual_val_mem)->ptr());

    result.set_total_sample_size(total_sample_size);
    fill_actual_vals<<<grid_size, block_size_, 0, stream>>>(
        val,
        result.actual_val,
        actual_sample_size,
        cumsum_actual_sample_size_p,
        sample_size,
        len);
    CUDA_CHECK(cudaStreamSynchronize(stream));  // hbm safe
  }

  cudaStreamSynchronize(stream);
  return result;
}

// only for graphsage
NeighborSampleResultV2 GpuPsGraphTable::graph_neighbor_sample_all_edge_type(
    int gpu_id,
    int edge_type_len,
    uint64_t* key,
    int sample_size,
    int len,
    std::vector<std::shared_ptr<phi::Allocation>> edge_type_graphs) {
  NeighborSampleResultV2 result;
  auto stream = resource_->local_stream(gpu_id, 0);
  result.set_stream(stream);
  result.initialize(sample_size, len, edge_type_len, resource_->dev_id(gpu_id));
  if (len == 0) {
    return result;
  }

  platform::CUDAPlace place = platform::CUDAPlace(resource_->dev_id(gpu_id));
  platform::CUDADeviceGuard guard(resource_->dev_id(gpu_id));

  int* actual_sample_size = result.actual_sample_size;
  uint64_t* val = result.val;
  int total_gpu = resource_->total_device();

  int grid_size = (len - 1) / block_size_ + 1;
  int h_left[total_gpu];   // NOLINT
  int h_right[total_gpu];  // NOLINT
  auto d_left =
      memory::Alloc(place,
                    total_gpu * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  auto d_right =
      memory::Alloc(place,
                    total_gpu * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_left_ptr = reinterpret_cast<int*>(d_left->ptr());
  int* d_right_ptr = reinterpret_cast<int*>(d_right->ptr());
  int default_value = 0;
  CUDA_CHECK(cudaMemsetAsync(d_left_ptr, -1, total_gpu * sizeof(int), stream));
  CUDA_CHECK(cudaMemsetAsync(d_right_ptr, -1, total_gpu * sizeof(int), stream));

  auto d_idx =
      memory::Alloc(place,
                    len * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_idx_ptr = reinterpret_cast<int*>(d_idx->ptr());
  auto d_shard_keys =
      memory::Alloc(place,
                    len * sizeof(uint64_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  uint64_t* d_shard_keys_ptr = reinterpret_cast<uint64_t*>(d_shard_keys->ptr());
  auto d_shard_vals =
      memory::Alloc(place,
                    sample_size * len * edge_type_len * sizeof(uint64_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  uint64_t* d_shard_vals_ptr = reinterpret_cast<uint64_t*>(d_shard_vals->ptr());
  auto d_shard_actual_sample_size =
      memory::Alloc(place,
                    len * edge_type_len * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_shard_actual_sample_size_ptr =
      reinterpret_cast<int*>(d_shard_actual_sample_size->ptr());

  split_input_to_shard(reinterpret_cast<uint64_t*>(key),
                       d_idx_ptr,
                       len,
                       d_left_ptr,
                       d_right_ptr,
                       gpu_id);

  heter_comm_kernel_->fill_shard_key(
      d_shard_keys_ptr, key, d_idx_ptr, len, stream);

  CUDA_CHECK(cudaStreamSynchronize(stream));

  CUDA_CHECK(cudaMemcpyAsync(h_left,
                             d_left_ptr,
                             total_gpu * sizeof(int),
                             cudaMemcpyDeviceToHost,
                             stream));
  CUDA_CHECK(cudaMemcpyAsync(h_right,
                             d_right_ptr,
                             total_gpu * sizeof(int),
                             cudaMemcpyDeviceToHost,
                             stream));
  CUDA_CHECK(cudaStreamSynchronize(stream));

  device_mutex_[gpu_id]->lock();
  for (int i = 0; i < total_gpu; ++i) {
    int shard_len = h_left[i] == -1 ? 0 : h_right[i] - h_left[i] + 1;
    if (shard_len == 0) {
      continue;
    }
    create_storage(
        gpu_id,
        i,
        shard_len * sizeof(uint64_t),
        shard_len * sizeof(uint64_t) * edge_type_len +  // key
            (shard_len * sample_size * sizeof(uint64_t)) *
                edge_type_len +                        // sample
            shard_len * sizeof(int) * edge_type_len +  // actual sample size
            ((shard_len * edge_type_len) % 2) * sizeof(int));  // align
  }
  walk_to_dest(gpu_id,
               total_gpu,
               h_left,
               h_right,
               reinterpret_cast<uint64_t*>(d_shard_keys_ptr),
               NULL);

  for (int i = 0; i < total_gpu; ++i) {
    if (h_left[i] == -1) {
      continue;
    }
    int shard_len = h_left[i] == -1 ? 0 : h_right[i] - h_left[i] + 1;
    auto& node = path_[gpu_id][i].nodes_.back();
    CUDA_CHECK(cudaMemsetAsync(node.val_storage,
                               0,
                               shard_len * edge_type_len * sizeof(uint64_t),
                               node.in_stream));
    CUDA_CHECK(cudaStreamSynchronize(node.in_stream));
    platform::CUDADeviceGuard guard(resource_->dev_id(i));

    GpuPsNodeInfo* node_info_base =
        reinterpret_cast<GpuPsNodeInfo*>(node.val_storage);
    for (int idx = 0; idx < edge_type_len; idx++) {
      int table_offset = get_table_offset(i, GraphTableType::EDGE_TABLE, idx);
      int offset = get_graph_list_offset(i, idx);
      if (tables_[table_offset] == NULL) {
        continue;
      }
      tables_[table_offset]->get(
          reinterpret_cast<uint64_t*>(node.key_storage),
          reinterpret_cast<uint64_t*>(node_info_base + idx * shard_len),
          static_cast<size_t>(shard_len),
          resource_->remote_stream(i, gpu_id));
    }

    auto d_commgraph_mem = edge_type_graphs[i];
    GpuPsCommGraph* d_commgraph_ptr =
        reinterpret_cast<GpuPsCommGraph*>(d_commgraph_mem->ptr());
    int* actual_size_base =
        reinterpret_cast<int*>(node_info_base + shard_len * edge_type_len);
    uint64_t* sample_array_base = reinterpret_cast<uint64_t*>(
        actual_size_base + shard_len * edge_type_len +
        (shard_len * edge_type_len) % 2);
    int grid_size_ = (shard_len * edge_type_len - 1) / block_size_ + 1;
    neighbor_sample_kernel_all_edge_type<<<grid_size_,
                                           block_size_,
                                           0,
                                           resource_->remote_stream(i,
                                                                    gpu_id)>>>(
        d_commgraph_ptr,
        node_info_base,
        actual_size_base,
        sample_array_base,
        sample_size,
        shard_len * edge_type_len,
        default_value,
        shard_len);
  }

  for (int i = 0; i < total_gpu; ++i) {
    if (h_left[i] == -1) {
      continue;
    }
    CUDA_CHECK(cudaStreamSynchronize(resource_->remote_stream(i, gpu_id)));
  }

  move_result_to_source_gpu_all_edge_type(gpu_id,
                                          total_gpu,
                                          sample_size,
                                          h_left,
                                          h_right,
                                          d_shard_vals_ptr,
                                          d_shard_actual_sample_size_ptr,
                                          edge_type_len,
                                          len);

  int grid_size_e = (len * edge_type_len - 1) / block_size_ + 1;
  fill_dvalues_with_edge_type<<<grid_size_e, block_size_, 0, stream>>>(
      d_shard_vals_ptr,
      val,
      d_shard_actual_sample_size_ptr,
      actual_sample_size,
      d_idx_ptr,
      sample_size,
      len * edge_type_len,
      len);
  CUDA_CHECK(cudaStreamSynchronize(stream));

  for (int i = 0; i < total_gpu; i++) {
    int shard_len = h_left[i] == -1 ? 0 : h_right[i] - h_left[i] + 1;
    if (shard_len == 0) {
      continue;
    }
    destroy_storage(gpu_id, i);
  }
  device_mutex_[gpu_id]->unlock();
  return result;
}

void GpuPsGraphTable::get_node_degree(
    int gpu_id,
    int edge_idx,
    uint64_t* key,
    int len,
    std::shared_ptr<phi::Allocation> node_degree) {
  int* node_degree_ptr =
      reinterpret_cast<int*>(node_degree->ptr()) + edge_idx * len;
  int total_gpu = resource_->total_device();
  platform::CUDAPlace place = platform::CUDAPlace(resource_->dev_id(gpu_id));
  platform::CUDADeviceGuard guard(resource_->dev_id(gpu_id));
  auto stream = resource_->local_stream(gpu_id, 0);
  int grid_size = (len - 1) / block_size_ + 1;
  int h_left[total_gpu];   // NOLINT
  int h_right[total_gpu];  // NOLINT
  auto d_left =
      memory::Alloc(place,
                    total_gpu * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  auto d_right =
      memory::Alloc(place,
                    total_gpu * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_left_ptr = reinterpret_cast<int*>(d_left->ptr());
  int* d_right_ptr = reinterpret_cast<int*>(d_right->ptr());
  CUDA_CHECK(cudaMemsetAsync(d_left_ptr, -1, total_gpu * sizeof(int), stream));
  CUDA_CHECK(cudaMemsetAsync(d_right_ptr, -1, total_gpu * sizeof(int), stream));
  auto d_idx =
      memory::Alloc(place,
                    len * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_idx_ptr = reinterpret_cast<int*>(d_idx->ptr());
  auto d_shard_keys =
      memory::Alloc(place,
                    len * sizeof(uint64_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  uint64_t* d_shard_keys_ptr = reinterpret_cast<uint64_t*>(d_shard_keys->ptr());
  auto d_shard_degree =
      memory::Alloc(place,
                    len * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_shard_degree_ptr = reinterpret_cast<int*>(d_shard_degree->ptr());
  split_input_to_shard(
      (uint64_t*)(key), d_idx_ptr, len, d_left_ptr, d_right_ptr, gpu_id);
  heter_comm_kernel_->fill_shard_key(
      d_shard_keys_ptr, key, d_idx_ptr, len, stream);
  CUDA_CHECK(cudaStreamSynchronize(stream));
  CUDA_CHECK(cudaMemcpyAsync(h_left,
                             d_left_ptr,
                             total_gpu * sizeof(int),
                             cudaMemcpyDeviceToHost,
                             stream));
  CUDA_CHECK(cudaMemcpyAsync(h_right,
                             d_right_ptr,
                             total_gpu * sizeof(int),
                             cudaMemcpyDeviceToHost,
                             stream));
  CUDA_CHECK(cudaStreamSynchronize(stream));
  device_mutex_[gpu_id]->lock();
  for (int i = 0; i < total_gpu; ++i) {
    int shard_len = h_left[i] == -1 ? 0 : h_right[i] - h_left[i] + 1;
    if (shard_len == 0) {
      continue;
    }
    create_storage(
        gpu_id,
        i,
        shard_len * sizeof(uint64_t),
        shard_len * sizeof(uint64_t) + sizeof(int) * shard_len + shard_len % 2);
  }
  walk_to_dest(
      gpu_id, total_gpu, h_left, h_right, (uint64_t*)(d_shard_keys_ptr), NULL);
  for (int i = 0; i < total_gpu; ++i) {
    if (h_left[i] == -1) {
      continue;
    }
    int shard_len = h_left[i] == -1 ? 0 : h_right[i] - h_left[i] + 1;
    auto& node = path_[gpu_id][i].nodes_.back();
    CUDA_CHECK(cudaMemsetAsync(
        node.val_storage, 0, shard_len * sizeof(uint64_t), node.in_stream));
    CUDA_CHECK(cudaStreamSynchronize(node.in_stream));
    platform::CUDADeviceGuard guard(resource_->dev_id(i));
    int table_offset =
        get_table_offset(i, GraphTableType::EDGE_TABLE, edge_idx);
    tables_[table_offset]->get(reinterpret_cast<uint64_t*>(node.key_storage),
                               reinterpret_cast<uint64_t*>(node.val_storage),
                               (size_t)(h_right[i] - h_left[i] + 1),
                               resource_->remote_stream(i, gpu_id));
    GpuPsNodeInfo* node_info_list =
        reinterpret_cast<GpuPsNodeInfo*>(node.val_storage);
    int* node_degree_array = (int*)(node_info_list + shard_len);
    int grid_size_ = (shard_len - 1) / block_size_ + 1;
    get_node_degree_kernel<<<grid_size_,
                             block_size_,
                             0,
                             resource_->remote_stream(i, gpu_id)>>>(
        node_info_list, node_degree_array, shard_len);
  }
  for (int i = 0; i < total_gpu; ++i) {
    if (h_left[i] == -1) {
      continue;
    }
    CUDA_CHECK(cudaStreamSynchronize(resource_->remote_stream(i, gpu_id)));
  }
  move_degree_to_source_gpu(
      gpu_id, total_gpu, h_left, h_right, d_shard_degree_ptr);
  fill_dvalues<<<grid_size, block_size_, 0, stream>>>(
      d_shard_degree_ptr, node_degree_ptr, d_idx_ptr, len);
  CUDA_CHECK(cudaStreamSynchronize(stream));
  for (int i = 0; i < total_gpu; i++) {
    int shard_len = h_left[i] == -1 ? 0 : h_right[i] - h_left[i] + 1;
    if (shard_len == 0) {
      continue;
    }
    destroy_storage(gpu_id, i);
  }
  device_mutex_[gpu_id]->unlock();
}

NodeQueryResult GpuPsGraphTable::graph_node_sample(int gpu_id,
                                                   int sample_size) {
  return NodeQueryResult();
}

NodeQueryResult GpuPsGraphTable::query_node_list(int gpu_id,
                                                 int idx,
                                                 int start,
                                                 int query_size) {
  NodeQueryResult result;
  result.actual_sample_size = 0;
  if (query_size <= 0) return result;
  std::vector<int> gpu_begin_pos, local_begin_pos;
  std::function<int(int, int, int, int, int&, int&)> range_check =
      [](int x, int y, int x1, int y1, int& x2, int& y2) {
        if (y <= x1 || x >= y1) return 0;
        y2 = min(y, y1);
        x2 = max(x1, x);
        return y2 - x2;
      };

  int offset = get_graph_list_offset(gpu_id, idx);
  const auto& graph = gpu_graph_list_[offset];
  if (graph.node_size == 0) {
    return result;
  }
  int x2, y2;
  int len = range_check(start, start + query_size, 0, graph.node_size, x2, y2);

  if (len == 0) {
    return result;
  }

  result.initialize(len, resource_->dev_id(gpu_id));
  result.actual_sample_size = len;
  uint64_t* val = result.val;

  int dev_id_i = resource_->dev_id(gpu_id);
  platform::CUDADeviceGuard guard(dev_id_i);
  int grid_size = (len - 1) / block_size_ + 1;
  node_query_example<<<grid_size,
                       block_size_,
                       0,
                       resource_->remote_stream(gpu_id, gpu_id)>>>(
      graph, x2, len, reinterpret_cast<uint64_t*>(val));
  CUDA_CHECK(cudaStreamSynchronize(resource_->remote_stream(gpu_id, gpu_id)));
  return result;
}

int GpuPsGraphTable::get_feature_info_of_nodes(
    int gpu_id,
    uint64_t* d_nodes,
    int node_num,
    uint32_t* size_list,
    uint32_t* size_list_prefix_sum,
    std::shared_ptr<phi::Allocation>& feature_list,
    std::shared_ptr<phi::Allocation>& slot_list) {
  if (node_num == 0) {
    return 0;
  }
  platform::CUDAPlace place = platform::CUDAPlace(resource_->dev_id(gpu_id));
  platform::CUDADeviceGuard guard(resource_->dev_id(gpu_id));
  int total_gpu = resource_->total_device();
  auto stream = resource_->local_stream(gpu_id, 0);

  auto d_left =
      memory::Alloc(place,
                    total_gpu * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  auto d_right =
      memory::Alloc(place,
                    total_gpu * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_left_ptr = reinterpret_cast<int*>(d_left->ptr());
  int* d_right_ptr = reinterpret_cast<int*>(d_right->ptr());

  CUDA_CHECK(cudaMemsetAsync(d_left_ptr, -1, total_gpu * sizeof(int), stream));
  CUDA_CHECK(cudaMemsetAsync(d_right_ptr, -1, total_gpu * sizeof(int), stream));
  auto d_idx =
      memory::Alloc(place,
                    node_num * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_idx_ptr = reinterpret_cast<int*>(d_idx->ptr());

  auto d_shard_keys =
      memory::Alloc(place,
                    node_num * sizeof(uint64_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  uint64_t* d_shard_keys_ptr = reinterpret_cast<uint64_t*>(d_shard_keys->ptr());
  split_input_to_shard(
      d_nodes, d_idx_ptr, node_num, d_left_ptr, d_right_ptr, gpu_id);

  heter_comm_kernel_->fill_shard_key(
      d_shard_keys_ptr, d_nodes, d_idx_ptr, node_num, stream);
  CUDA_CHECK(cudaStreamSynchronize(stream));

  std::vector<void*> d_fea_info(total_gpu, NULL);
  std::vector<void*> d_fea_size(total_gpu, NULL);
  std::vector<void*> d_fea_size_prefix_sum(total_gpu, NULL);
  std::vector<uint32_t> fea_num_list(total_gpu, 0);
  std::vector<int> fea_left(total_gpu, -1);

  int h_left[total_gpu];  // NOLINT
  CUDA_CHECK(cudaMemcpy(
      h_left, d_left_ptr, total_gpu * sizeof(int), cudaMemcpyDeviceToHost));
  int h_right[total_gpu];  // NOLINT
  CUDA_CHECK(cudaMemcpy(
      h_right, d_right_ptr, total_gpu * sizeof(int), cudaMemcpyDeviceToHost));
  device_mutex_[gpu_id]->lock();
  int shard_len[total_gpu];  // NOLINT
  void* d_temp_storage[total_gpu];
  std::vector<size_t> temp_storage_bytes(total_gpu, 0);

  for (int i = 0; i < total_gpu; ++i) {
    shard_len[i] = h_left[i] == -1 ? 0 : h_right[i] - h_left[i] + 1;
    d_temp_storage[i] = NULL;
    if (h_left[i] == -1) {
      continue;
    }
    create_storage(gpu_id, i, shard_len[i] * sizeof(uint64_t), 0);
    platform::CUDADeviceGuard guard(resource_->dev_id(i));
    auto& node = path_[gpu_id][i].nodes_.back();
    create_tmp_storage(
        d_fea_info[i], gpu_id, i, shard_len[i] * sizeof(uint64_t));
    CUDA_CHECK(cudaMemsetAsync(
        d_fea_info[i], 0, shard_len[i] * sizeof(uint64_t), node.in_stream));
    create_tmp_storage(
        d_fea_size[i], gpu_id, i, shard_len[i] * sizeof(uint32_t));
    create_tmp_storage(d_fea_size_prefix_sum[i],
                       gpu_id,
                       i,
                       (shard_len[i] + 1) * sizeof(uint32_t));
    CUDA_CHECK(cub::DeviceScan::InclusiveSum(
        NULL,
        temp_storage_bytes[i],
        reinterpret_cast<uint32_t*>(d_fea_size[i]),
        reinterpret_cast<uint32_t*>(d_fea_size_prefix_sum[i] + 1),
        shard_len[i],
        resource_->remote_stream(i, gpu_id)));
  }

  for (int i = 0; i < total_gpu; ++i) {
    if (h_left[i] == -1) {
      continue;
    }
    platform::CUDADeviceGuard guard(resource_->dev_id(i));
    CUDA_CHECK(cudaStreamSynchronize(resource_->remote_stream(
        i, gpu_id)));  // wait for calc temp_storage_bytes
    create_tmp_storage(d_temp_storage[i], gpu_id, i, temp_storage_bytes[i]);
  }
  walk_to_dest(gpu_id,
               total_gpu,
               h_left,
               h_right,
               reinterpret_cast<uint64_t*>(d_shard_keys_ptr),
               NULL);

  // no sync so 8 card can parallel execute
  for (int i = 0; i < total_gpu; ++i) {
    if (h_left[i] == -1) {
      continue;
    }
    platform::CUDADeviceGuard guard(resource_->dev_id(i));
    auto& node = path_[gpu_id][i].nodes_.back();
    // If not found, val is -1.
    int table_offset = get_table_offset(i, GraphTableType::FEATURE_TABLE, 0);
    CUDA_CHECK(cudaStreamSynchronize(
        node.in_stream));  // wait for walk_to_dest and memset
    tables_[table_offset]->get(reinterpret_cast<uint64_t*>(node.key_storage),
                               reinterpret_cast<uint64_t*>(d_fea_info[i]),
                               static_cast<size_t>(h_right[i] - h_left[i] + 1),
                               resource_->remote_stream(i, gpu_id));
    dim3 grid((shard_len[i] - 1) / dim_y + 1);
    dim3 block(1, dim_y);

    get_features_size<<<grid, block, 0, resource_->remote_stream(i, gpu_id)>>>(
        reinterpret_cast<GpuPsFeaInfo*>(d_fea_info[i]),
        reinterpret_cast<uint32_t*>(d_fea_size[i]),
        shard_len[i]);
    CUDA_CHECK(cudaMemsetAsync(d_fea_size_prefix_sum[i],
                               0,
                               sizeof(uint32_t),
                               resource_->remote_stream(i, gpu_id)));
    CUDA_CHECK(cub::DeviceScan::InclusiveSum(
        d_temp_storage[i],
        temp_storage_bytes[i],
        reinterpret_cast<uint32_t*>(d_fea_size[i]),
        reinterpret_cast<uint32_t*>(d_fea_size_prefix_sum[i]) + 1,
        shard_len[i],
        resource_->remote_stream(i, gpu_id)));
  }

  // wait for fea_num_list
  for (int i = 0; i < total_gpu; ++i) {
    platform::CUDADeviceGuard guard(resource_->dev_id(i));
    if (h_left[i] == -1) {
      continue;
    }
    auto& node = path_[gpu_id][i].nodes_.back();
    CUDA_CHECK(cudaMemcpyAsync(
        &fea_num_list[i],
        reinterpret_cast<uint32_t*>(d_fea_size_prefix_sum[i]) + shard_len[i],
        sizeof(uint32_t),
        cudaMemcpyDeviceToHost,
        resource_->remote_stream(i, gpu_id)));

    CUDA_CHECK(cudaStreamSynchronize(
        resource_->remote_stream(i, gpu_id)));  // wait for fea_num_list

    create_storage(gpu_id,
                   i,
                   0,
                   (shard_len[i] + shard_len[i] % 2) * sizeof(uint32_t) +
                       fea_num_list[i] * sizeof(uint64_t) +
                       fea_num_list[i] * sizeof(uint8_t));
    uint32_t* actual_size_array = reinterpret_cast<uint32_t*>(node.val_storage);
    CUDA_CHECK(cudaMemcpyAsync(actual_size_array,
                               d_fea_size[i],
                               sizeof(uint32_t) * shard_len[i],
                               cudaMemcpyDeviceToDevice,
                               resource_->remote_stream(i, gpu_id)));
    int offset = get_graph_fea_list_offset(i);
    auto graph = gpu_graph_fea_list_[offset];

    uint64_t* feature_array = reinterpret_cast<uint64_t*>(
        actual_size_array + shard_len[i] + shard_len[i] % 2);
    uint8_t* slot_array =
        reinterpret_cast<uint8_t*>(feature_array + fea_num_list[i]);
    dim3 grid((shard_len[i] - 1) / dim_y + 1);
    dim3 block(1, dim_y);
    get_features_kernel<<<grid,
                          block,
                          0,
                          resource_->remote_stream(i, gpu_id)>>>(
        graph,
        reinterpret_cast<GpuPsFeaInfo*>(d_fea_info[i]),
        reinterpret_cast<uint32_t*>(d_fea_size_prefix_sum[i]),
        feature_array,
        slot_array,
        shard_len[i]);
  }

  for (int i = 0; i < total_gpu; ++i) {
    if (h_left[i] == -1) {
      continue;
    }
    CUDA_CHECK(cudaStreamSynchronize(resource_->remote_stream(i, gpu_id)));
  }

  uint32_t all_fea_num = 0;
  for (int i = 0; i < total_gpu; ++i) {
    fea_left[i] = all_fea_num;
    all_fea_num += fea_num_list[i];
  }

  auto feature_list_tmp =
      memory::Alloc(place,
                    all_fea_num * sizeof(uint64_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  uint64_t* d_feature_list_ptr =
      reinterpret_cast<uint64_t*>(feature_list_tmp->ptr());

  auto slot_list_tmp =
      memory::Alloc(place,
                    all_fea_num * sizeof(uint8_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  uint8_t* d_slot_list_ptr = reinterpret_cast<uint8_t*>(slot_list_tmp->ptr());

  auto size_list_tmp =
      memory::Alloc(place,
                    node_num * sizeof(uint32_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  uint32_t* d_size_list_ptr = reinterpret_cast<uint32_t*>(size_list_tmp->ptr());

  move_result_to_source_gpu(gpu_id,
                            total_gpu,
                            h_left,
                            h_right,
                            fea_left.data(),
                            fea_num_list.data(),
                            d_size_list_ptr,
                            d_feature_list_ptr,
                            d_slot_list_ptr);

  for (int i = 0; i < total_gpu; ++i) {
    if (shard_len[i] == 0) {
      continue;
    }
    destroy_storage(gpu_id, i);
    if (d_fea_info[i] != NULL) {
      destroy_tmp_storage(d_fea_info[i], gpu_id, i);
    }
    if (d_fea_size[i] != NULL) {
      destroy_tmp_storage(d_fea_size[i], gpu_id, i);
    }
    if (d_fea_size_prefix_sum[i] != NULL) {
      destroy_tmp_storage(d_fea_size_prefix_sum[i], gpu_id, i);
    }
    if (d_temp_storage[i] != NULL) {
      destroy_tmp_storage(d_temp_storage[i], gpu_id, i);
    }
  }

  d_fea_info.clear();
  d_fea_size.clear();
  d_fea_size_prefix_sum.clear();
  device_mutex_[gpu_id]->unlock();
  feature_list =
      memory::Alloc(place,
                    all_fea_num * sizeof(uint64_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));

  uint64_t* d_res_feature_list_ptr =
      reinterpret_cast<uint64_t*>(feature_list->ptr());

  slot_list =
      memory::Alloc(place,
                    all_fea_num * sizeof(uint8_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));

  uint8_t* d_res_slot_list_ptr = reinterpret_cast<uint8_t*>(slot_list->ptr());

  int grid_size = (node_num - 1) / block_size_ + 1;
  fill_size<<<grid_size, block_size_, 0, stream>>>(
      size_list, d_size_list_ptr, d_idx_ptr, node_num);
  size_t storage_bytes = 0;
  auto src_fea_size_prefix_sum =
      memory::Alloc(place,
                    node_num * sizeof(uint32_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));

  uint32_t* src_fea_size_prefix_sum_ptr =
      reinterpret_cast<uint32_t*>(src_fea_size_prefix_sum->ptr());
  CUDA_CHECK(cudaStreamSynchronize(stream));
  CUDA_CHECK(cub::DeviceScan::ExclusiveSum(
      NULL, storage_bytes, size_list, size_list_prefix_sum, node_num, stream));
  CUDA_CHECK(cudaStreamSynchronize(stream));
  auto d_temp_storage_tmp =
      memory::Alloc(place,
                    storage_bytes,
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  CUDA_CHECK(cub::DeviceScan::ExclusiveSum(d_temp_storage_tmp->ptr(),
                                           storage_bytes,
                                           size_list,
                                           size_list_prefix_sum,
                                           node_num,
                                           stream));

  CUDA_CHECK(cub::DeviceScan::ExclusiveSum(d_temp_storage_tmp->ptr(),
                                           storage_bytes,
                                           d_size_list_ptr,
                                           src_fea_size_prefix_sum_ptr,
                                           node_num,
                                           stream));
  fill_feature_and_slot<<<grid_size, block_size_, 0, stream>>>(
      d_res_feature_list_ptr,
      d_res_slot_list_ptr,
      size_list_prefix_sum,
      d_feature_list_ptr,
      d_slot_list_ptr,
      src_fea_size_prefix_sum_ptr,
      d_size_list_ptr,
      d_idx_ptr,
      node_num);

  CUDA_CHECK(cudaStreamSynchronize(stream));
  return all_fea_num;
}

int GpuPsGraphTable::get_feature_of_nodes(int gpu_id,
                                          uint64_t* d_nodes,
                                          uint64_t* d_feature,
                                          int node_num,
                                          int slot_num,
                                          int* d_slot_feature_num_map,
                                          int fea_num_per_node) {
  if (node_num == 0) {
    return -1;
  }

  platform::CUDAPlace place = platform::CUDAPlace(resource_->dev_id(gpu_id));
  platform::CUDADeviceGuard guard(resource_->dev_id(gpu_id));
  int total_gpu = resource_->total_device();
  auto stream = resource_->local_stream(gpu_id, 0);

  auto d_left =
      memory::Alloc(place,
                    total_gpu * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  auto d_right =
      memory::Alloc(place,
                    total_gpu * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_left_ptr = reinterpret_cast<int*>(d_left->ptr());
  int* d_right_ptr = reinterpret_cast<int*>(d_right->ptr());

  CUDA_CHECK(cudaMemsetAsync(d_left_ptr, -1, total_gpu * sizeof(int), stream));
  CUDA_CHECK(cudaMemsetAsync(d_right_ptr, -1, total_gpu * sizeof(int), stream));
  //
  auto d_idx =
      memory::Alloc(place,
                    node_num * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_idx_ptr = reinterpret_cast<int*>(d_idx->ptr());

  auto d_shard_keys =
      memory::Alloc(place,
                    node_num * sizeof(uint64_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  uint64_t* d_shard_keys_ptr = reinterpret_cast<uint64_t*>(d_shard_keys->ptr());
  auto d_shard_vals =
      memory::Alloc(place,
                    fea_num_per_node * node_num * sizeof(uint64_t),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  uint64_t* d_shard_vals_ptr = reinterpret_cast<uint64_t*>(d_shard_vals->ptr());
  auto d_shard_actual_size =
      memory::Alloc(place,
                    node_num * sizeof(int),
                    phi::Stream(reinterpret_cast<phi::StreamId>(stream)));
  int* d_shard_actual_size_ptr =
      reinterpret_cast<int*>(d_shard_actual_size->ptr());

  split_input_to_shard(
      d_nodes, d_idx_ptr, node_num, d_left_ptr, d_right_ptr, gpu_id);

  heter_comm_kernel_->fill_shard_key(
      d_shard_keys_ptr, d_nodes, d_idx_ptr, node_num, stream);
  CUDA_CHECK(cudaStreamSynchronize(stream));

  int h_left[total_gpu];  // NOLINT
  CUDA_CHECK(cudaMemcpy(
      h_left, d_left_ptr, total_gpu * sizeof(int), cudaMemcpyDeviceToHost));
  int h_right[total_gpu];  // NOLINT
  CUDA_CHECK(cudaMemcpy(
      h_right, d_right_ptr, total_gpu * sizeof(int), cudaMemcpyDeviceToHost));
  device_mutex_[gpu_id]->lock();
  for (int i = 0; i < total_gpu; ++i) {
    int shard_len = h_left[i] == -1 ? 0 : h_right[i] - h_left[i] + 1;
    if (shard_len == 0) {
      continue;
    }
    create_storage(gpu_id,
                   i,
                   shard_len * sizeof(uint64_t),
                   shard_len * fea_num_per_node * sizeof(uint64_t) +
                       shard_len * sizeof(uint64_t) +
                       sizeof(int) * (shard_len + shard_len % 2));
  }

  walk_to_dest(gpu_id,
               total_gpu,
               h_left,
               h_right,
               reinterpret_cast<uint64_t*>(d_shard_keys_ptr),
               NULL);

  for (int i = 0; i < total_gpu; ++i) {
    if (h_left[i] == -1) {
      continue;
    }
    int shard_len = h_left[i] == -1 ? 0 : h_right[i] - h_left[i] + 1;
    auto& node = path_[gpu_id][i].nodes_.back();

    CUDA_CHECK(cudaMemsetAsync(
        node.val_storage, 0, shard_len * sizeof(uint64_t), node.in_stream));
    CUDA_CHECK(cudaStreamSynchronize(node.in_stream));
    platform::CUDADeviceGuard guard(resource_->dev_id(i));
    // If not found, val is -1.
    int table_offset = get_table_offset(i, GraphTableType::FEATURE_TABLE, 0);
    tables_[table_offset]->get(reinterpret_cast<uint64_t*>(node.key_storage),
                               reinterpret_cast<uint64_t*>(node.val_storage),
                               static_cast<size_t>(h_right[i] - h_left[i] + 1),
                               resource_->remote_stream(i, gpu_id));

    int offset = get_graph_fea_list_offset(i);
    auto graph = gpu_graph_fea_list_[offset];

    GpuPsFeaInfo* val_array = reinterpret_cast<GpuPsFeaInfo*>(node.val_storage);
    int* actual_size_array = reinterpret_cast<int*>(val_array + shard_len);
    uint64_t* feature_array = reinterpret_cast<uint64_t*>(
        actual_size_array + shard_len + shard_len % 2);
    dim3 grid((shard_len - 1) / dim_y + 1);
    dim3 block(1, dim_y);
    get_features_kernel<<<grid,
                          block,
                          0,
                          resource_->remote_stream(i, gpu_id)>>>(
        graph,
        val_array,
        actual_size_array,
        feature_array,
        d_slot_feature_num_map,
        slot_num,
        shard_len,
        fea_num_per_node);
  }

  for (int i = 0; i < total_gpu; ++i) {
    if (h_left[i] == -1) {
      continue;
    }
    CUDA_CHECK(cudaStreamSynchronize(resource_->remote_stream(i, gpu_id)));
  }

  move_result_to_source_gpu(gpu_id,
                            total_gpu,
                            fea_num_per_node,
                            h_left,
                            h_right,
                            d_shard_vals_ptr,
                            d_shard_actual_size_ptr);
  for (int i = 0; i < total_gpu; ++i) {
    int shard_len = h_left[i] == -1 ? 0 : h_right[i] - h_left[i] + 1;
    if (shard_len == 0) {
      continue;
    }
    destroy_storage(gpu_id, i);
  }
  device_mutex_[gpu_id]->unlock();

  int grid_size = (node_num - 1) / block_size_ + 1;
  fill_dvalues<<<grid_size, block_size_, 0, stream>>>(d_shard_vals_ptr,
                                                      d_feature,
                                                      d_shard_actual_size_ptr,
                                                      d_idx_ptr,
                                                      fea_num_per_node,
                                                      node_num);

  CUDA_CHECK(cudaStreamSynchronize(stream));

  return 0;
}

};  // namespace framework
};  // namespace paddle
#endif
