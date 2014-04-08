// 
// Copyright 2011-2012 Jeff Bush
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
// 

`include "defines.v"

//
// Cache tag memory. This assumes 4 ways, but has a parameterizable number 
// of sets.  This stores both a valid bit for each cache line and the tag
// (the upper bits of the virtual address).  It handles checking for a cache
// hit and updating the tags when data is laoded from memory.
// Since there are four ways, there are also four separate tag RAM blocks, which 
// the address is issued to in parallel. 
// Tag memory has one cycle of latency. cache_hit_o and hit_way_o will be valid
// in the next cycle after request_addr is asserted.
//

module l1_cache_tag
	#(parameter ENABLE_TLB = 0)

	(input                             clk,
	input                              reset,
	
	// Request
	input                              access_i,
	input[25:0]                        request_addr,
	input[`ASID_BITS - 1:0]            request_asid,
	
	// Response	
	output [1:0]                       hit_way_o,
	output                             cache_hit_o,
	output                             tlb_miss_o,
	output [25:0]                      tlb_pa_o,

	// Update (from L2 cache)
	input                              update_i,
	input                              invalidate_one_way,
	input                              invalidate_all_ways,
	input[1:0]                         update_way_i,
	input[`L1_TAG_WIDTH - 1:0]         update_tag_i,
	input[`L1_SET_INDEX_WIDTH - 1:0]   update_set_i,
	
	// TLB update
	input                              update_tlb_va_en,
	input                              update_tlb_pa_en,
	input [`TLB_INDEX_BITS - 1:0]      update_tlb_index,
	input [31:0]                       update_tlb_value);

	logic[`L1_TAG_WIDTH * 4 - 1:0] tag;
	logic[`L1_NUM_WAYS - 1:0] valid;
	logic access_latched;
	logic[25:0] request_va_latched;
	logic[25:0] request_pa_latched;
	logic[`PAGE_INDEX_BITS - 1:0] tlb_phys_addr;
	logic[`L1_NUM_WAYS - 1:0] update_way;
	logic mmu_enable_latched;

	wire[`L1_SET_INDEX_WIDTH - 1:0] requested_set_index = request_addr[`L1_SET_INDEX_WIDTH - 1:0];
	wire[`L1_TAG_WIDTH - 1:0] requested_tag = request_addr[25:`L1_SET_INDEX_WIDTH];

	cache_valid_array #(.NUM_SETS(`L1_NUM_SETS)) valid_mem[`L1_NUM_WAYS - 1:0] (
		.clk(clk),
		.reset(reset),
		.rd_enable(access_i),
		.rd_addr(requested_set_index),
		.rd_is_valid(valid),
		.wr_addr(update_set_i),
		.wr_is_valid(update_i),
		.wr_enable(update_way));

	sram_1r1w #(.DATA_WIDTH(`L1_TAG_WIDTH), .SIZE(`L1_NUM_SETS)) tag_mem[`L1_NUM_WAYS - 1:0] (
		.clk(clk),
		.rd_addr(requested_set_index),
		.rd_data(tag),
		.rd_enable(access_i),
		.wr_addr(update_set_i),
		.wr_data(update_tag_i),
		.wr_enable(update_way));
		
	logic tlb_hit;

	generate
		if (ENABLE_TLB)
		begin
			logic [`TLB_INDEX_BITS - 1:0] tlb_hit_index;
		
			cam #(.NUM_ENTRIES(`NUM_TLB_ENTRIES), .KEY_WIDTH($bits(request_asid) + $bits(request_addr))) tlb_cam(
				.lookup_key({request_asid, request_addr}),
				.lookup_index(tlb_hit_index),
				.lookup_hit(tlb_hit),
				.update_en(update_tlb_va_en),
				.update_key(update_tlb_value),
				.update_index(update_tlb_index),
				.update_valid(update_tlb_value[31:`PAGE_INDEX_BITS] != 0),	// Setting ASID to 0 invalidates
				.*);

			sram_1r1w #(.DATA_WIDTH(`PAGE_INDEX_BITS), .SIZE(`NUM_TLB_ENTRIES)) tlb_mem(
				.rd_enable(access_i),
				.rd_addr(tlb_hit_index),
				.rd_data(tlb_phys_addr),
				.wr_enable(update_tlb_pa_en),
				.wr_addr(update_tlb_index),
				.wr_data(update_tlb_value[`PAGE_INDEX_BITS - 1:0]),
				.*);
		end
	endgenerate
		
	always_ff @(posedge clk, posedge reset)
	begin
		if (reset)
		begin
			/*AUTORESET*/
			// Beginning of autoreset for uninitialized flops
			access_latched <= 1'h0;
			mmu_enable_latched <= 1'h0;
			request_va_latched <= 26'h0;
			// End of automatics
		end
		else
		begin
			// update_i and invalidate_one_way should not both be asserted
			assert(!(update_i && invalidate_one_way));

			// Make sure more than one way isn't a hit
			assert($onehot0(hit_way_oh) || !access_latched);

			// Cache hit should not be asserted when there is a TLB miss.
			assert(!(cache_hit_o && tlb_miss_o));

			access_latched <= access_i;
			request_va_latched <= request_addr;
			mmu_enable_latched <= request_asid != 0;	// ASID 0 is hard coded to map 1:1 phys/virtual
		end
	end

	generate
		if (ENABLE_TLB)
		begin
			assign request_pa_latched = mmu_enable_latched 
				? { tlb_phys_addr, {25 - $bits(tlb_phys_addr){1'b0}} } 
				: request_va_latched;
		end
		else
			assign request_pa_latched = request_va_latched;
	endgenerate
	
	assign tlb_pa_o = request_pa_latched;
	
	logic [`L1_NUM_WAYS - 1:0] hit_way_oh;
	genvar way;
	generate
		for (way = 0; way < `L1_NUM_WAYS; way++)
		begin : makeway
			assign hit_way_oh[way] = tag[way * `L1_TAG_WIDTH+:`L1_TAG_WIDTH] ==
				request_pa_latched[25:`L1_SET_INDEX_WIDTH] && valid[way];
			assign update_way[way] = ((invalidate_one_way || update_i) 
				&& update_way_i == way) || invalidate_all_ways;
		end
	endgenerate
	
	assign tlb_miss_o = access_latched && !tlb_hit && mmu_enable_latched;

	one_hot_to_index #(.NUM_SIGNALS(`L1_NUM_WAYS)) cvt_hit_way(
		.one_hot(hit_way_oh),
		.index(hit_way_o));

	assign cache_hit_o = |hit_way_oh && access_latched;

endmodule

// Local Variables:
// verilog-typedef-regexp:"_t$"
// End:

