// A photo identifies a place, not elapsed playback. Never use the decorative
// wall clock for route progress. POI IDs retain the catalog identity (3=rare).
module b_route_clock(input movie,input [3:0] poi,input [31:0] media_ms,
 output reg [31:0] route_ms);
always @*begin
 if(movie)route_ms=media_ms>72000?32'd72000:media_ms;
 else case(poi)
  1:route_ms=0;
  2:route_ms=20000;
  4:route_ms=37000;
  3:route_ms=57000;
  default:route_ms=0;
 endcase
end
endmodule
