//
// Copyright (C) 2014 Jeff Bush
// 
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
// 
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
// 
// You should have received a copy of the GNU Library General Public
// License along with this library; if not, write to the
// Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
// Boston, MA  02110-1301, USA.
//

`include "defines.v"

//
// L2 cache pipeline - read stage
// Check for cache hit and read cache data memory
//

module l2_cache_read(
	input                                     clk,
	input                                     reset,

	// From l2_cache_tag                     
	input l2req_packet_t                      l2t_request,
	input                                     l2t_valid[`L2_WAYS],
	input l2_tag_t                            l2t_tag[`L2_WAYS],
	input                                     l2t_dirty[`L2_WAYS],
	input                                     l2t_is_l2_fill,
	input l2_way_idx_t                        l2t_fill_way,
	input [`CACHE_LINE_BITS - 1:0]            l2t_data_from_memory,
	
	// To l2_cache_tag.  Update metadata.
	output logic[`L2_WAYS - 1:0]              l2r_update_dirty_en,
	output l2_set_idx_t                       l2r_update_dirty_set,
	output logic                              l2r_update_dirty_value,
	output logic[`L2_WAYS - 1:0]              l2r_update_tag_en,
	output l2_set_idx_t                       l2r_update_tag_set,
	output logic                              l2r_update_tag_valid,
	output l2_tag_t                           l2r_update_tag_value,
	output logic                              l2r_update_lru_en,
	output l2_way_idx_t                       l2r_update_lru_hit_way,
                                             
	// from l2_cache_write                   
	input                                     l2u_write_en,
	input [$clog2(`L2_WAYS * `L2_SETS) - 1:0] l2u_write_addr,
	input [`CACHE_LINE_BITS - 1:0]            l2u_write_data,
                                              
	// To l2_cache_write                   
	output l2req_packet_t                     l2r_request,
	output logic[`CACHE_LINE_BITS - 1:0]      l2r_data,	// Also to bus interface unit
	output logic                              l2r_cache_hit,
	output logic[$clog2(`L2_WAYS * `L2_SETS) - 1:0] l2r_hit_cache_idx,
	output logic                              l2r_is_l2_fill,
	output [`CACHE_LINE_BITS - 1:0]           l2r_data_from_memory,
	output logic                              l2r_store_sync_success,
	
	// To bus interface unit
	output l2_tag_t                           l2r_replace_tag,
	output logic                              l2r_replace_needs_writeback,
	
	// Debug
	output logic                              DEBUG_is_sync_store,
	output logic                              DEBUG_is_sync_load,
	output thread_idx_t                       DEBUG_sync_id,
	output logic                              DEBUG_sync_store_success,
	output scalar_t                           DEBUG_sync_address);
	

	localparam TOTAL_THREADS = `NUM_CORES * `THREADS_PER_CORE;

	// Track synchronized load/stores, and determine if a synchronized store
	// was successful.
	logic[25:0] sync_load_address[0:TOTAL_THREADS - 1]; 
	logic sync_load_address_valid[0:TOTAL_THREADS - 1];
	logic can_store_sync;

	logic[`L2_WAYS - 1:0] hit_way_oh;
	l2_addr_t l2_addr;
	logic cache_hit;
	l2_way_idx_t hit_way_idx;
	logic[$clog2(`L2_WAYS * `L2_SETS) - 1:0] read_address;
	logic is_store;
	logic update_dirty;
	logic update_tag;
	
	assign l2_addr = l2t_request.address;
	assign is_store = l2t_request.packet_type == L2REQ_STORE 
		|| l2t_request.packet_type == L2REQ_STORE_SYNC;

	assign DEBUG_is_sync_store = l2t_request.valid && l2t_request.packet_type == L2REQ_STORE_SYNC;
	assign DEBUG_is_sync_load = l2t_request.valid && l2t_request.packet_type == L2REQ_LOAD_SYNC;
	assign DEBUG_sync_id = l2t_request.id;
	assign DEBUG_sync_store_success = can_store_sync;
	assign DEBUG_sync_address = l2t_request.address;

	// 
	// Check for cache hit
	//
	genvar way_idx;
	generate
		for (way_idx = 0; way_idx < `L2_WAYS; way_idx++)
		begin : hit_way_gen
			assign hit_way_oh[way_idx] = l2_addr.tag == l2t_tag[way_idx] && l2t_valid[way_idx]; 
		end
	endgenerate

	assign cache_hit = |hit_way_oh && l2t_request.valid;

	oh_to_idx #(.NUM_SIGNALS(`L2_WAYS)) oh_to_idx_hit_way(
		.one_hot(hit_way_oh),
		.index(hit_way_idx));

	// If this is a fill, read the old (potentially dirty line) so it can be written back.
	// If it is a cache hit, read the line data.
	assign read_address = { (l2t_is_l2_fill ? l2t_fill_way : hit_way_idx), l2_addr.set_idx };

	//
	// Cache memory
	//
	sram_1r1w #(
		.DATA_WIDTH(`CACHE_LINE_BITS), 
		.SIZE(`L2_WAYS * `L2_SETS)
	) sram_l2_data(
		.read_en(l2t_request.valid && (cache_hit || l2t_is_l2_fill)),
		.read_addr(read_address),
		.read_data(l2r_data),
		.write_en(l2u_write_en),	
		.write_addr(l2u_write_addr),
		.write_data(l2u_write_data),
		.*);

	//
	// Update dirty bits.  If this is a fill, initialize the dirty bit to the correct
	// value depending on whether this is a write.  If it is a cache hit, update the
	// dirty bit only if this is a store.
	//
	assign update_dirty = l2t_request.valid && (l2t_is_l2_fill
		|| (cache_hit && is_store));
	assign l2r_update_dirty_set = l2_addr.set_idx;
	assign l2r_update_dirty_value = is_store;

	genvar dirty_update_idx;
	generate
		for (dirty_update_idx = 0; dirty_update_idx < `L2_WAYS; dirty_update_idx++)
		begin : dirty_update_gen
			assign l2r_update_dirty_en[dirty_update_idx] = update_dirty 
				&& (l2t_is_l2_fill ? l2t_fill_way == dirty_update_idx : hit_way_oh[dirty_update_idx]);
		end
	endgenerate
	
	//
	// Update tag memory
	//
	assign update_tag = l2t_is_l2_fill;
	genvar tag_update_idx;
	generate
		for (tag_update_idx = 0; tag_update_idx < `L2_WAYS; tag_update_idx++)
		begin : tag_update_gen
			assign l2r_update_tag_en[tag_update_idx] = update_tag && l2t_fill_way == tag_update_idx;
		end
	endgenerate

	assign l2r_update_tag_set = l2_addr.set_idx;
	assign l2r_update_tag_valid = 1'b1;
	assign l2r_update_tag_value = l2_addr.tag;

	// 
	// Update LRU
	//
	assign l2r_update_lru_en = cache_hit;
	assign l2r_update_lru_hit_way = hit_way_idx;

	//
	// Synchronized requests
	//
	assign can_store_sync = sync_load_address[{ l2t_request.core, l2t_request.id}] 
		== {l2_addr.tag, l2_addr.set_idx} 
		&& sync_load_address_valid[{l2t_request.core, l2t_request.id}]
		&& l2t_request.packet_type == L2REQ_STORE_SYNC;

	always_ff @(posedge clk, posedge reset)
	begin
		if (reset)
		begin
			l2r_request <= 0;
			l2r_cache_hit <= 0;
			l2r_is_l2_fill <= 0;
			l2r_replace_tag <= 0;
			l2r_replace_needs_writeback <= 0;
			l2r_data_from_memory <= 0;
			l2r_store_sync_success <= 0;
			for (int i = 0; i < TOTAL_THREADS; i++)
				sync_load_address_valid[i] <= 0;
		end
		else
		begin
			// A fill and cache hit cannot occur at the same time.
			assert(!l2t_is_l2_fill || !cache_hit);

			l2r_request <= l2t_request;
			l2r_cache_hit <= cache_hit;
			l2r_is_l2_fill <= l2t_is_l2_fill;
			l2r_replace_tag <= l2t_tag[l2t_fill_way];
			l2r_replace_needs_writeback <= l2t_dirty[l2t_fill_way] && l2t_valid[l2t_fill_way];
			l2r_data_from_memory <= l2t_data_from_memory;
			l2r_hit_cache_idx <= read_address;

			if (l2t_request.valid && (cache_hit || l2t_is_l2_fill))
			begin
				// Track synchronized load/stores
				unique case (l2t_request.packet_type)
					L2REQ_LOAD_SYNC:
					begin
						sync_load_address[{l2t_request.core, l2t_request.id}] <= {l2_addr.tag, l2_addr.set_idx};
						sync_load_address_valid[{l2t_request.core, l2t_request.id}] <= 1;
					end
		
					L2REQ_STORE,
					L2REQ_STORE_SYNC:
					begin
						// Note that we don't invalidate if the sync store is 
						// not successful.  Otherwise strands can livelock.
						if (l2t_request.packet_type == L2REQ_STORE || can_store_sync)
						begin
							// Invalidate
							for (int entry_idx = 0; entry_idx < TOTAL_THREADS; entry_idx++)
							begin
								if (sync_load_address[entry_idx] == {l2_addr.tag, l2_addr.set_idx})
									sync_load_address_valid[entry_idx] <= 0;
							end
						end
					end

					default:
						;
				endcase

				l2r_store_sync_success <= can_store_sync;
			end
			else
				l2r_store_sync_success <= 0;
		end
	end
endmodule

// Local Variables:
// verilog-typedef-regexp:"_t$"
// End:
