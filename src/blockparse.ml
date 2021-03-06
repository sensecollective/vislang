open Blockify
open Errors
open Xst

let print_list program = String.concat "\n\n" 
    (List.map (fun x -> (x :> base) #print_obj) program)

(* Block Parse intelligently traces through the objects inside a block from
 * output to input and finds an appropiate path through the block such
 * that when the code is extracted from the order obtained here,
 * the program is consistent and no runtimes issues occur. *)
let rec block_parse top =
    (* Algorithm: 
     * The block trace algorithm will get the list of outputs from the
     * current block level, and recursively traverse the current object
     * list by finding the connection made from each input (starting at
     * the output), and tracing it back to it's last output. The recursion
     * will continue until either: an input is found (terminate that branch),
     * a memory block is found (terminate that branch, and add memory's input
     * to the list of traversals), a traversal is made to an object on the list
     * of priors (terminate branch), or an algebraic loop is detected (raise
     * error if the next traversal is already in the list of traversals made).
     * At the termination of a traversal for an output, all of the objects
     * detected are consistent and the entire list of objects is added to the
     * list of priors. This process continues until all output and memory
     * blocks successfully traverse back to inputs or priors branches. *)
    let rec trace block_list prior_list trace_list current =
        let compare_obj n = (fun x -> (x :> base) #name = n)in
        match ((current :> base) #print_class) with
            "input"
          | "constant"
          | "dt"        -> if List.exists (compare_obj current#name) prior_list
                           || List.exists (compare_obj current#name) trace_list
                           (* If terminating block exists in EITHER
                            * list, exclude *)
                           then trace_list
                           else current :: trace_list
          | _ as blk    ->
            (* If current object exists in the current trace loop,
             * this means there's a cyclic reference in the trace that
             * will not be possible to escape, e.g. algebraic loop *)
            if List.exists (compare_obj current#name) trace_list
            then object_error (blk ^ ": " ^ ((current :> base) #name) ^
                                     " is in an algebraic loop...")
            (* If current object exists on the list of priors, that means
             * that value is already computed and will not need to be 
             * computed again. *)
            else if List.exists (compare_obj current#name) prior_list
                 then trace_list
                 (* Default case: kick off trace for each connected input 
                  * in current object's list of inputs *)
                 else if (blk = "memory") && ((List.length trace_list) > 0) 
                      then trace_list (* Terminate trace at memory block
                                       * if one is found as an input *)
                 else
                  (* First find and verify all inputs connected to current
                   * block, matching them to the relevant blocks for further
                   * recursion. Next, set names of current blocks to the 
                   * outputs of those blocks correctly such that they can
                   * be printed correctly in SSA form without error.
                   * Note: need to handle blocks (function calls) separetely
                   * using the REF type so that SSA works.
                   * Note: In order to link current block to inputs, we
                   * need to replace input names for current block with
                   * the output names of the corresponding parts. E.g.
                   * block name for basic parts and structured defs
                   * for block and reference function calls. *)
                    let (new_inputs, input_names) = 
                        List.split
                            (List.map
                                (fun x -> let ref = current#get_connection x.name
                                     in match ref with 
                                            Name n -> ({
                                                            name = n; 
                                                            datatype = x.datatype
                                                       }, 
                                                       n)
                                          (* When a reference is found, assume
                                           * the function call completed and we
                                           * are extracting the relevant output 
                                           * to that block here. *)
                                          | Ref r  -> 
                                            if r.reftype = "NAME"
                                            then if ((List.length r.reflist) = 1)
                                               then let cnx = (List.hd r.reflist)
                                                   in ({ name = r.refroot ^ 
                                                               "_outputs." ^ 
                                                               cnx;
                                                        datatype = x.datatype
                                                     }, r.refroot)
                                                 else object_error
                                                    ("Cannot reference more " ^
                                                    "than 1 deep for blocks")
                                            else object_error 
                                                ("FILE reference type " ^
                                                "not supported for ref " ^
                                                    (string_of_ref r)
                                                )
                                          | _ as attr -> object_error 
                                                ("Attribute " ^ 
                                                 (string_of_value attr) ^ 
                                                 " not supported.") 
                                )
                                ((current :> base) #inputs)
                            )
                      (* Compute the list of inputs to the current block 
                       * to split path and continue traversal *)
                      in let input_list =
                                (List.map
                                    (fun x ->
                                        (List.find 
                                            (compare_obj x) 
                                            block_list
                                        )
                                    )
                                    input_names
                                )
                   in ((current :> base) #set_inputs new_inputs);
                      let trace_list = current :: trace_list
                   in trace_split block_list prior_list trace_list input_list
    (* for each input of a block, trace out the list from that point on *)
    and trace_split block_list prior_list trace_list input_list =
        match input_list with
            []          -> trace_list
          | hd :: tl    -> let trace_list = 
                                (trace block_list prior_list trace_list hd)
                            in trace_split block_list prior_list trace_list tl
            
    (* trace_start function: this function is the wrapper used to call the
     * inner trace algorithm. It recurses through the list of start objects,
     * applying the trace algorithm for each object, then appending the result
     * to the list of priors for the next recursion *)
     in 
     let rec trace_start block_list prior_list start_list =
        match start_list with
            []       -> List.rev prior_list (* reverse list here because we were
                                             * traversing backwards above *)
          | hd :: tl -> let prior_list = prior_list @ 
                            (trace block_list prior_list [] hd)
                         in trace_start block_list prior_list tl

    (* start_list: the list of objects in the top block used to prime the trace 
     * algorithm. All outputs and memory blocks are added to the start list
     * because they are the termination of the code the block will generate *)
     in 
    let inner_objs obj = (obj :> base) #inner_objs
     in
    let start_list obj = 
       (List.filter 
            (fun x -> (x :> base) #print_class = "output")
            (inner_objs obj)
       ) 
     @ (List.filter
            (fun x -> (x :> base) #print_class = "memory")
            (inner_objs obj)
       )
     in
    (* Perform the same mutation operations for any inner blocks of top. 
     * Note: at this point, if an inner object was not used, it should not appear
     * in the code for top below. *)
    let inner_block_list = List.filter 
                            (fun x-> (x :> base) #print_class = "block") 
                            (inner_objs top)
     in
    (* Perform the trace operation and re-set the inner objects of top with the
     * result. Also print objects that will be removed. *)
    let new_inner_objs = (trace_start (inner_objs top) [] (start_list top))
     in
    top#set_inner_objs new_inner_objs;
    (* Return a list of blocks with properly configured inner objects
     * to be used for compilation. Note: we reverse the list here so that 
     * inner_blks are first to be compiled. *)
    List.rev (top :: List.flatten (List.map block_parse inner_block_list))
