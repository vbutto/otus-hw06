const http = require('http');

const port = process.env.PORT ? Number(process.env.PORT) : 3000;

const server = http.createServer((req, res) => {
  const now = new Date().toISOString();
  res.writeHead(200, { 'Content-Type': 'text/plain' });

  // Добавляем простейшую проверку здоровья
  if (req.url === '/health') {
    res.end('OK');
  } else {
    res.end(`Hello from HW06! Time: ${now}\n`);
  }
});

server.listen(port, () => {
  console.log(`Server listening on port ${port}`);
});
