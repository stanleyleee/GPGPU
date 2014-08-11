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
// Queue store requests from the instruction pipeline, send store requests to L2 
// interconnect, and process responses.
//

module l1_store_queue(
	input                                  clk,
	input                                  reset,
                                           
	// From dache data stage               
	input                                  dd_store_en,
	input l1d_addr_t                       dd_store_addr,
	input [`CACHE_LINE_BYTES - 1:0]        dd_store_mask,
	input [`CACHE_LINE_BITS - 1:0]         dd_store_data,
	input                                  dd_store_synchronized,
	input thread_idx_t                     dd_store_thread_idx,
	input l1d_addr_t                       dd_store_bypass_addr,
	input thread_idx_t                     dd_store_bypass_thread_idx,
	
	// To writeback stage
	output [`CACHE_LINE_BYTES - 1:0]       sq_store_bypass_mask,
	output [`CACHE_LINE_BITS - 1:0]        sq_store_bypass_data,
	output logic                           sq_store_sync_success,
                                           
	// To l2_cache_interface           
	output logic                           sq_dequeue_ready,
	output scalar_t                        sq_dequeue_addr,
	output l1_miss_entry_idx_t             sq_dequeue_idx,
	output [`CACHE_LINE_BYTES - 1:0]       sq_dequeue_mask,
	output [`CACHE_LINE_BITS - 1:0]        sq_dequeue_data,
	output logic                           sq_dequeue_synchronized,
	output                                 sq_full_rollback_en,
	output logic[`THREADS_PER_CORE - 1:0]  sq_wake_bitmap,

	// From l2_cache_interface
	input                                  sq_dequeue_ack,
	input                                  storebuf_l2_response_valid,
	input l1_miss_entry_idx_t              storebuf_l2_response_idx,
	input                                  storebuf_l2_sync_success);

	struct packed {
		logic[`CACHE_LINE_BITS - 1:0] data;
		logic[`CACHE_LINE_BYTES - 1:0] mask;
		scalar_t address;

		// Keep single bit values at end of structure to work around verilator bug:
		// http://www.veripool.org/issues/803-Verilator-Writing-to-one-structure-element-clobbers-another
		logic synchronized;
		logic request_sent;
		logic response_received;
		logic sync_success;
		logic thread_waiting;
		logic valid;
	} pending_stores[`THREADS_PER_CORE];
	logic[`THREADS_PER_CORE - 1:0] rollback;
	logic[`THREADS_PER_CORE - 1:0] send_request;
	thread_idx_t send_grant_idx;
	logic[`THREADS_PER_CORE - 1:0] send_grant_oh;
	l1d_addr_t cache_aligned_store_addr;
	l1d_addr_t cache_aligned_bypass_addr;

	assign cache_aligned_store_addr.tag = dd_store_addr.tag;
	assign cache_aligned_store_addr.set_idx = dd_store_addr.set_idx;
	assign cache_aligned_store_addr.offset = 0;
	assign cache_aligned_bypass_addr.tag = dd_store_bypass_addr.tag;
	assign cache_aligned_bypass_addr.set_idx = dd_store_bypass_addr.set_idx;
	assign cache_aligned_bypass_addr.offset = 0;
	
	arbiter #(.NUM_ENTRIES(`THREADS_PER_CORE)) arbiter_send(
		.request(send_request),
		.update_lru(1'b1),
		.grant_oh(send_grant_oh),
		.*);

	oh_to_idx #(.NUM_SIGNALS(`THREADS_PER_CORE)) oh_to_idx_send_grant(
		.index(send_grant_idx),
		.one_hot(send_grant_oh));

	genvar thread_idx;
	generate
		for (thread_idx = 0; thread_idx < `THREADS_PER_CORE; thread_idx++)
		begin : thread_store_buf_gen
			logic update_store_data;
			logic can_write_combine;
			logic store_requested_this_entry;
			logic send_this_cycle;
			logic can_enqueue;
			logic is_restarted_sync_request;

			assign send_request[thread_idx] = pending_stores[thread_idx].valid
				&& !pending_stores[thread_idx].request_sent;
			assign store_requested_this_entry = dd_store_en && dd_store_thread_idx == thread_idx;
			assign send_this_cycle = send_grant_oh[thread_idx] && sq_dequeue_ack;
			assign can_write_combine = pending_stores[thread_idx].valid 
				&& pending_stores[thread_idx].address == cache_aligned_store_addr
				&& !pending_stores[thread_idx].synchronized 
				&& !dd_store_synchronized
				&& !pending_stores[thread_idx].request_sent
				&& !send_this_cycle;
			assign is_restarted_sync_request = pending_stores[thread_idx].valid
				&& pending_stores[thread_idx].response_received
				&& pending_stores[thread_idx].synchronized;
			assign update_store_data = store_requested_this_entry && (!pending_stores[thread_idx].valid
				|| can_write_combine) && !is_restarted_sync_request;
			assign sq_wake_bitmap[thread_idx] = storebuf_l2_response_valid 
				&& pending_stores[thread_idx].thread_waiting;

			always_comb
			begin
				rollback[thread_idx] = 0;
				if (store_requested_this_entry)
				begin
					// On the first synchronized store request, we always suspend the thread, even when there
					// is space in the buffer, because we must wait for a response.
					if (dd_store_synchronized)
						rollback[thread_idx] = !is_restarted_sync_request;
					else if (pending_stores[thread_idx].valid && !can_write_combine)
						rollback[thread_idx] = 1;
				end
			end

			always_ff @(posedge clk, posedge reset)
			begin
				if (reset)
				begin
					pending_stores[thread_idx] <= 0;
				end
				else 
				begin
					if (send_this_cycle)
						pending_stores[thread_idx].request_sent <= 1;

					if (update_store_data)
					begin
						for (int byte_lane = 0; byte_lane < `CACHE_LINE_BYTES; byte_lane++)
						begin
							if (dd_store_mask[byte_lane])
								pending_stores[thread_idx].data[byte_lane * 8+:8] <= dd_store_data[byte_lane * 8+:8];
						end
							
						if (can_write_combine)
							pending_stores[thread_idx].mask <= pending_stores[thread_idx].mask | dd_store_mask;
						else
							pending_stores[thread_idx].mask <= dd_store_mask;
					end

					if (sq_wake_bitmap[thread_idx])
						pending_stores[thread_idx].thread_waiting <= 0;

					if (store_requested_this_entry)
					begin
						if (rollback[thread_idx])
							pending_stores[thread_idx].thread_waiting <= 1;
						
						if (is_restarted_sync_request)
						begin
							// This is the restarted request after we finished a synchronized send.
							assert(pending_stores[thread_idx].response_received);
							assert(dd_store_synchronized);	// Restarted instruction must be synchronized
							pending_stores[thread_idx].valid <= 0;
						end
						else if (update_store_data && !can_write_combine)
						begin
							// New store
							
							// Ensure this entry isn't in use
							assert(!pending_stores[thread_idx].valid);
							
							pending_stores[thread_idx].valid <= 1;
							pending_stores[thread_idx].address <= cache_aligned_store_addr;
							pending_stores[thread_idx].synchronized <= dd_store_synchronized;
							pending_stores[thread_idx].request_sent <= 0;
							pending_stores[thread_idx].response_received <= 0;
						end
					end

					if (storebuf_l2_response_valid && storebuf_l2_response_idx == thread_idx)
					begin
						// Ensure we don't get a repsonse for an entry that isn't valid
						// or hasn't been sent.
						assert(pending_stores[thread_idx].valid);
						assert(pending_stores[thread_idx].request_sent);
						
						// When we receive a synchronized response, the entry is still valid until the thread
						// wakes back up and retrives the result.  If it is not synchronized, this finishes
						// the transaction.
						if (pending_stores[thread_idx].synchronized)
						begin
							pending_stores[thread_idx].response_received <= 1;
							pending_stores[thread_idx].sync_success <= storebuf_l2_sync_success;
						end
						else
							pending_stores[thread_idx].valid <= 0;
					end
				end
			end
		end
	endgenerate
	
	// New request out. 
	// XXX may want to register this to reduce latency.
	assign sq_dequeue_ready = |send_grant_oh;
	assign sq_dequeue_idx = send_grant_idx;
	assign sq_dequeue_addr = pending_stores[send_grant_idx].address;
	assign sq_dequeue_mask = pending_stores[send_grant_idx].mask;
	assign sq_dequeue_data = pending_stores[send_grant_idx].data;
	assign sq_dequeue_synchronized = pending_stores[send_grant_idx].synchronized;
	
	always_ff @(posedge clk, posedge reset)
	begin
		if (reset)
		begin
			sq_store_bypass_mask <= 0;
			sq_store_bypass_data <= 0;
			sq_store_sync_success <= 0;
			sq_full_rollback_en <= 0;
		end
		else
		begin
			// Can't assert wake and sleep signals in same cycle
			assert(!(sq_wake_bitmap & rollback));

			if (cache_aligned_bypass_addr == pending_stores[dd_store_bypass_thread_idx].address
				&& pending_stores[dd_store_bypass_thread_idx].valid)
			begin
				// There is a store for this address, set mask
				sq_store_bypass_mask <= pending_stores[dd_store_bypass_thread_idx].mask;
				sq_store_bypass_data <= pending_stores[dd_store_bypass_thread_idx].data;
			end
			else
				sq_store_bypass_mask <= 0;
		
			sq_store_sync_success <= pending_stores[dd_store_thread_idx].sync_success;
			sq_full_rollback_en <= |rollback;
		end
	end
endmodule

// Local Variables:
// verilog-typedef-regexp:"_t$"
// End:

