// --------------------------------------------------------------------------------------------------------------------
// IP Block    : ENoC
// Function    : Router
// Module name : ENoC_Router
// Description : Connects various modules together to create an input buffered router
// Uses        : config.sv, ENoC_Config.sv, LIB_FIFO_packet_t.sv, ENoC_RouteCalculator.sv,  
//             : LIB_Switch_OneHot_packet_t.sv, ENoC_SwitchControl.sv
// Notes       : Uses the packet_t typedef from config.sv.  packet_t contains node destination information as a single
//             : number encoded as logic.  If `PORTS is a function of 2^n this will not cause problems as the logic
//             : can simply be split in two, each half representing either the X or Y direction.  This will not work
//             : otherwise.
// --------------------------------------------------------------------------------------------------------------------

`include "ENoC_Config.sv"
`include "config.sv"

module ENoC_Router

#(parameter X_NODES, // Number of cores on the X axis of the Mesh
  parameter Y_NODES, // Number of cores on the Y axis of the Mesh 
  parameter X_LOC,   // location on the X axis of the Mesh
  parameter Y_LOC,   // location on the Y axis of the Mesh
  parameter N = 5,   // Number of input ports.  Fixed for 2D Mesh Router
  parameter M = 5)   // Number of output ports.  Fixed for 2D Mesh Router
 
 (input logic clk, reset_n,
  
  // Upstream Bus.
  // ------------------------------------------------------------------------------------------------------------------
  input  packet_t [0:N-1] i_data,     // Input data from upstream [core, north, east, south, west]
  input  logic    [0:N-1] i_data_val, // Validates data from upstream [core, north, east, south, west]
  output logic    [0:N-1] o_en,       // Enables data from upstream [core, north, east, south, west]
  
  // Downstream Bus
  // ------------------------------------------------------------------------------------------------------------------
  output packet_t [0:M-1] o_data,     // Outputs data to downstream [core, north, east, south, west]
  output logic    [0:M-1] o_data_val, // Validates output data to downstream [core, north, east, south, west]
  input  logic    [0:M-1] i_en);      // Enables output to downstream [core, north, east, south, west]
  
  // Local Signals common to VC and no VC instance
  // ------------------------------------------------------------------------------------------------------------------

         packet_t        [0:N-1] l_data;         // Connects FIFO data outputs to switch
         logic    [0:N-1][0:M-1] l_output_req;   // Request sent to SwitchControl
         logic    [0:M-1][0:N-1] l_output_grant; // Grant from SwitchControl, used to control switch and FIFOs

  `ifdef VC
  
    // Virtual Channels.  Five input FIFOs for each switch input.  The route calculation is performed on the packet
    // incoming to the router from the upstream router, the result of this calculation is used to decide which virtual
    // channel the incoming packet will be stored in.  The virtual channels output a word according to which FIFOs have
    // valid data.  This is used by the switch control for arbitration.
    // ----------------------------------------------------------------------------------------------------------------

         logic    [0:N-1][0:M-1] l_vc_req; // Connects the output request of the Route Calc to a VC
         logic    [0:N-1][0:M-1] l_en; // Connects switch control enable output to VCs
           
    generate
      for(genvar i=0; i<N; i++) begin
        LIB_VirtualChannel #(.M(M), .DEPTH(`FIFO_DEPTH))
          gen_LIB_VirtualChannel (.clk,
                                  .reset_n,
                                  .i_data(i_data[i]),           // Single input data from upstream router
                                  .i_data_val(l_vc_req[i]),     // Valid from routecalc corresponds to required VC
                                  .o_en(o_en[i]),               // Single enable signal to the upstream router
                                  .o_data(l_data[i]),           // Single output data to switch
                                  .o_data_val(l_output_req[i]), // Packed request word to SwitchControl
                                  .i_en(l_en[i]));              // Packed grant word from SwitchControl
      end
    endgenerate
    
    generate
      for (genvar i=0; i<N; i++) begin    
        ENoC_RouteCalculator #(.X_NODES(X_NODES), .Y_NODES(Y_NODES), .X_LOC(X_LOC), .Y_LOC(Y_LOC)) 
          gen_ENoC_RouteCalculator (.i_x_dest(i_data[i].dest[(log2(X_NODES*Y_NODES)/2)-1:0]),           
                                    .i_y_dest(i_data[i].dest[log2(X_NODES*Y_NODES)-1:(log2(X_NODES*Y_NODES)/2)]),
                                    .i_val(i_data_val[i]),        // From upstream router
                                    .o_output_req(l_vc_req[i]));  // To Switch Control
      end
    endgenerate
    
    // transposition of the output arbitration grant for indicating an enable to the VCs
    always_comb begin
      l_en = '0;
      for(int i=0; i<N; i++) begin
        for(int j=0; j<M; j++) begin
          l_en[i][j] = l_output_grant[j][i];
        end
      end
    end  
    
  `else
  
    // No virtual Channels.  Five input FIFOs, with a Route Calculator attached to the packet waiting at the output of
    // each FIFO.  The result of the route calculation is used by the switch control for arbitration.
    // ----------------------------------------------------------------------------------------------------------------

         logic            [0:N-1] l_data_val; // Connects FIFO valid output to the route calculator    
         logic            [0:N-1] l_en;       // Connects switch control enable output to FIFO

    generate
      for (genvar i=0; i<N; i++) begin
        LIB_FIFO_packet_t #(.DEPTH(`FIFO_DEPTH))
          gen_LIB_FIFO_packet_t (.clk,
                                 .reset_n,
                                 .i_data(i_data[i]),         // From the upstream routers
                                 .i_data_val(i_data_val[i]), // From the upstream routers
                                 .i_en(l_en[i]),             // From the SwitchControl
                                 .o_data(l_data[i]),         // To the Switch
                                 .o_data_val(l_data_val[i]), // To the route calculator
                                 .o_en(o_en[i]),             // To the upstream routers
                                 .o_full(),                  // Not connected, o_en used for flow control
                                 .o_empty(),                 // Not connected, not required for simple flow control
                                 .o_near_empty());           // Not connected, not required for simple flow control
      end
    endgenerate
    
    // Route calculator will output 5 packed words, each word corresponds to an input, each bit corresponds to the
    // output requested.
    // ----------------------------------------------------------------------------------------------------------------
    generate
      for (genvar i=0; i<N; i++) begin    
        ENoC_RouteCalculator #(.X_NODES(X_NODES), .Y_NODES(Y_NODES), .X_LOC(X_LOC), .Y_LOC(Y_LOC)) 
          gen_ENoC_RouteCalculator (.i_x_dest(l_data[i].dest[(log2(X_NODES*Y_NODES)/2)-1:0]),           
                                    .i_y_dest(l_data[i].dest[log2(X_NODES*Y_NODES)-1:(log2(X_NODES*Y_NODES)/2)]),
                                    .i_val(l_data_val[i]),                                      // From local FIFO
                                    .o_output_req(l_output_req[i]));                            // To Switch Control
      end
    endgenerate
    
    // indicate to input FIFOs, according to arbitration results, that data will be read.
    // ----------------------------------------------------------------------------------------------------------------
    always_comb begin
      l_en = '0;
      for(int j=0; j<M; j++) begin
        l_en |= l_output_grant[j];
        // equivalent to: l_en[0:N-1] = l_en[0:N-1] | l_output_grant[j][0:N-1];
      end
    end   
    
  `endif
 
  // Switch Control receives 5, 5-bit words, each word corresponds to an input, each bit corresponds to the requested
  // output.  This is combined with the enable signal from the downstream router, then arbitrated.  The result is
  // 5, 5-bit words each word corresponding to an output, each bit corresponding to an input (note the transposition).
  // ------------------------------------------------------------------------------------------------------------------  
  ENoC_SwitchControl #(.N(N), .M(M))
    inst_ENoC_SwitchControl (.clk,
                             .reset_n,
                             .i_en(i_en),                      // From the downstream router
                             .i_output_req(l_output_req),      // From the local VCs or Route Calculator
                             .o_output_grant(l_output_grant)); // To the local VCs or FIFOs
 
  // Switch.  Switch uses onehot input from switch control.
  // ------------------------------------------------------------------------------------------------------------------
  
  LIB_Switch_OneHot_packet_t #(.N(N), .M(M))
    inst_LIB_Switch_OneHot_packet_t (.i_sel(l_output_grant), // From the Switch Control
                                     .i_data(l_data),        // From the local FIFOs
                                     .o_data(o_data));       // To the downstream routers
  

  // Output to downstream routers that the switch data is valid
  // ------------------------------------------------------------------------------------------------------------------                      
  always_comb begin
  o_data_val = '0;
    for (int i=0; i<M; i++) begin  
      o_data_val[i]  = |l_output_grant[i];
    end
  end
  
  

endmodule