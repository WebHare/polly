// Fixed API-shaped snapshots: no production monitoring data.
const now = "2026-11-16T12:00:00Z";
const counts = {hosts:48,hostsDown:0,services:216,critical:0,warning:0,unknown:0,pending:0};
const server = {id:"source-1",name:"Production",state:"ok",stale:false,ageSeconds:12,lastAttemptAt:now,lastSuccessAt:now};
const base = {generatedAt:now,staleAfterSeconds:150,state:"ok",mood:"ok",headline:"Polly is quiet. Go back to sleep.",coverage:{active:2,fresh:2},counts,servers:[server,{...server,id:"source-2",name:"Staging"}],problems:[]};
const problem = {id:"p-1",serverID:"source-1",serverName:"Production",host:"web-01.example.com",service:"HTTP",severity:"critical",since:"2026-11-16T11:46:00Z",output:"HTTP CRITICAL: HTTP/1.1 503 Service Unavailable",longOutput:"Backend health check failed.\nResponse time: 3.015 seconds",acknowledged:false,downtimeDepth:0};
export const fixtures = {
  quiet:base,
  warning:{...base,state:"problems",mood:"warning",headline:"Polly is fidgeting: 1 warning",counts:{...counts,warning:1},problems:[{...problem,severity:"warning",output:"WARNING: Disk usage is 84%",service:"Disk /var",acknowledged:true}]},
  critical:{...base,state:"problems",mood:"critical",headline:"Polly is squawking: 2 critical",counts:{...counts,hostsDown:1,critical:2,warning:1,unknown:1},problems:[problem,{...problem,id:"p-2",host:"db-02.example.com",service:"PostgreSQL",output:"CRITICAL: connection refused",downtimeDepth:1},{...problem,id:"p-3",severity:"warning",host:"storage-01.example.com",service:"Disk /data",output:"WARNING: 86% of disk space used",acknowledged:true},{...problem,id:"p-4",severity:"unknown",host:"worker-04.example.com",service:"Queue depth",output:"UNKNOWN: No result returned"}]},
  unknown:{...base,state:"problems",mood:"unreachable",headline:"Polly is confused: 1 unknown",counts:{...counts,unknown:1},problems:[{...problem,severity:"unknown",output:"UNKNOWN: No result returned"}]},
  unreachable:{...base,state:"unreachable",mood:"unreachable",headline:"Polly can't reach the monitoring servers",coverage:{active:2,fresh:0},servers:base.servers.map(s=>({...s,state:"unreachable",stale:true}))},
  empty:{...base,state:"empty",mood:"unreachable",headline:"Polly has nothing to watch yet",coverage:{active:0,fresh:0},counts:{hosts:0,hostsDown:0,services:0,critical:0,warning:0,unknown:0,pending:0},servers:[]},
  paused:{...base,state:"paused",mood:"unreachable",headline:"Polly is not watching: all servers are paused",coverage:{active:0,fresh:0},servers:base.servers.map(s=>({...s,state:"paused"}))},
  waiting:{...base,state:"waiting",mood:"unreachable",headline:"Polly is checking your servers",coverage:{active:2,fresh:0},servers:base.servers.map(s=>({...s,state:"loading",stale:true,ageSeconds:null}))},
  partial:{...base,state:"partial",mood:"unreachable",headline:"Polly is missing current data from some checks",coverage:{active:2,fresh:1},servers:[server,{...server,id:"source-2",name:"Staging",state:"unreachable",stale:true}]},
};
fixtures.long = {...fixtures.critical,problems:[{...problem,host:"very-long-host-name-".repeat(12),service:"long-service-name-".repeat(12),serverName:"long-source-name-".repeat(10),output:'<img src=x onerror="alert(1)"> & <script>alert(2)</script> '+"literal-output-".repeat(50),longOutput:"line\n".repeat(40)},...fixtures.critical.problems.slice(1)]};
fixtures.eight = {...fixtures.critical,counts:{...counts,critical:8},headline:"Polly is squawking: 8 critical",problems:Array.from({length:8},(_,i)=>({...problem,id:`p-${i}`,host:`web-${i+1}.example.com`}))};
fixtures.five = {...fixtures.eight,counts:{...counts,critical:5},headline:"Polly is squawking: 5 critical",problems:fixtures.eight.problems.slice(0,5)};
