// Simple allocator with fixed slot size
// Asumes a single FIFO in adapter - therefore grants are single bit
// Philip Watts 4/4/2013

`include "config.sv"

module alloc_simple (
  output  logic      [0:`PORTS-1][log2(`PORTS):0]  grant,
  output  logic      [0:`PORTS-1][`PORTS-1:0]      grant_switch,
  input   logic      [0:`PORTS-1][log2(`PORTS):0]  req,
  input   logic                                    clk,
  input   logic                                    rst);
  
  // Internal signals
  logic [0:`PORTS-1][`PORTS-1:0][log2(`FIFO_DEPTH):0]  req_int ;  
  logic [0:`PORTS-1][4:0]              grant_counters; // later make size of counters optimum
  logic [0:`PORTS-1][`PORTS-1:0]       ry          ; 
  logic [0:`PORTS-1][`PORTS-1:0]       gy          ; 
  logic [0:`PORTS-1][`PORTS-1:0]       grant_int   ; 
  logic [0:`PORTS-1][`PORTS-1:0]       grant_switch_int_y;
  logic [0:`PORTS-1][`PORTS-1:0]       grant_switch_int_x;
  logic [0:`PORTS-1][log2(`PORTS)-1:0] grant_ports;
  
  `ifdef VC
    
    // Specific signals for VC network
    logic [0:`PORTS-1][`PORTS-1:0]       inty; 
    logic [0:`PORTS-1][`PORTS-1:0]       intx;   
    logic [0:`PORTS-1][log2(`PORTS)-1:0] grant_port;
    
    // Instantiate arbiters			
    generate
      for (genvar h=0;h<`PORTS;h++) begin
        arbiter #(`PORTS) output_arbiter(.clk(clk), .ce(|gy[h]), .r(ry[h]), .g(inty[h]), .rst(rst));
        arbiter #(`PORTS) input_arbiter(.clk(clk), .ce(1'b1), .r(intx[h]), .g(grant_int[h]), .rst(rst));
      end
    endgenerate	
  
  `else
  
    // Instantiate arbiters			
    generate for (genvar h=0;h<`PORTS;h++)
      arbiter #(`PORTS) output_arbiter(
        .clk(clk), 
        .ce(1'b1), 
        .r(ry[h]), 
        .g(gy[h]), 
        .rst(rst));
    endgenerate	
  
  `endif
  
  // Create internal request matrix
  // Counts requests so only a single request is sent per message
  always_ff @(posedge clk)
    if (rst) 
      for (int k=0;k<`PORTS;k++)
        for (int j=0;j<`PORTS;j++)
          req_int[k][j] <= 0;
    else
      for (int k=0;k<`PORTS;k++)
			   for (int j=0;j<`PORTS;j++)
				    if ((req[k][log2(`PORTS)]==1'b1) && (req[k][log2(`PORTS)-1:0]==j)) begin
				      if (!grant_int[k][j])	begin  
					       req_int[k][j] <= req_int[k][j] + 1;
              end
            end else if (grant_int[k][j]) begin
              req_int[k][j] <= req_int[k][j] - 1;
            end					       
  
  // Register grants and store grants for switch
  // Replace grants to switch buffer with by shift register in later version
  always_ff @(posedge clk)
    if (rst)
      for (int k=0;k<`PORTS;k++) begin
        grant[k]          <= 0;
        grant_switch[k]   <= 0;
      end
    else begin
      grant_switch      <=  grant_switch_int_y;
      for (int j=0;j<`PORTS;j++)
        `ifdef VC
            grant[j]      <=  {|grant_int[j], grant_port[j]}; 
        `else
            grant[j][0]   <=  |grant_int[j];
        `endif
    end
    
    `ifdef VC
    // This block converts the grant matrix from
    // 1hot to binary with the correct width
    always_comb                   
      for (int j=0;j<`PORTS;j++)  
        grant_port[j] = log2(grant_int[j]);
    `endif
        
   // Rotate matices (comb)
   always_comb
     for (int k=0;k<`PORTS;k++) begin
       for (int j=0;j<`PORTS;j++) begin
          `ifdef VC
              intx[k][j] = inty[j][k];
              gy[k][j]   = grant_int[j][k];
          `else
              grant_int[k][j] =   gy[j][k];
          `endif
         grant_switch_int_x[k][j] = grant_switch_int_y[j][k];
       end
     end
      
  // Create requests for arbs, including rotate (comb)
  always_comb
    for (int k=0;k<`PORTS;k++) begin
      for (int j=0;j<`PORTS;j++) begin
        // consider changing the 2nd and 3rd conditions below to optimise slot timing 
        if ((req_int[k][j] > 0) & (~|grant_switch_int_y[j]) & (~|grant_switch_int_x[k])) 
          ry[j][k]  =   1'b1;
        else
          ry[j][k]  =   1'b0;
      end
    end
  
  // Grant counters
  always_ff @(posedge clk)
    if (rst)
      for (int k=0;k<`PORTS;k++) begin
        grant_counters[k] <= `SLOT_SIZE-1;
        grant_ports[k]    <= 0;
    end else
      for (int k=0;k<`PORTS;k++)
        if (|gy[k]) begin
          grant_counters[k] <= 0;
          grant_ports[k] <= log2(gy[k]);
        end else if (grant_counters[k]<`SLOT_SIZE-1)
          grant_counters[k] <= grant_counters[k] + 1;
          
  // Define switch matrix (grouped by output ports)
  always_comb
    for (int k=0;k<`PORTS;k++) begin
      grant_switch_int_y[k] = 0;
      if (grant_counters[k]<`SLOT_SIZE-1)
        grant_switch_int_y[k][grant_ports[k]] = 1'b1;
    end
      
    
endmodule
