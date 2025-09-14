const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.get('/', (_req, res) => {
  res.send('Hello from Node.js on GKE via LoadBalancer! 🚀');
});

app.listen(PORT, () => {
  console.log(`App listening on port ${PORT}`);
});
