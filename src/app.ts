import express, { type Request, type Response } from 'express';

const app = express();

app.get('/', (_req: Request, res: Response) => {
  res.send('Hello againfrom TypeScript on EC2!');
});

app.get('/health', (_req: Request, res: Response) => {
  res.json({ status: 'ok' });
});

export default app;
