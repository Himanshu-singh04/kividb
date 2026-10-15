// Forward localhost:<listen> to <host>:<port>, for a test suite that assumes
// its server is on localhost. In Node because the client container has it:
// installing socat needed the network on every run, and when the network was
// down every test failed with ECONNREFUSED — a harness failure that read as
// 760 failing tests.
//
//   node forward.js <listen-port> <host> <port>
const net = require('net');
const [listen, host, port] = process.argv.slice(2);
const server = net.createServer(client => {
  const upstream = net.connect({ host, port: Number(port) });
  client.setNoDelay(true);
  upstream.setNoDelay(true);
  client.pipe(upstream);
  upstream.pipe(client);
  const close = () => { client.destroy(); upstream.destroy(); };
  client.on('error', close);
  upstream.on('error', close);
  client.on('close', close);
  upstream.on('close', close);
});
server.listen(Number(listen), '127.0.0.1');
