import request from 'supertest';
import { describe, expect, it } from 'vitest';
import app from '../src/app.ts';

describe('GET /', () => {
  it('returns 200 with the greeting message', async () => {
    const res = await request(app).get('/');
    expect(res.status).toBe(200);
    expect(res.text).toBe('Hello againfrom TypeScript on EC2!');
  });
});

describe('GET /health', () => {
  it('returns 200 with {"status":"ok"}', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/application\/json/);
    expect(res.body).toEqual({ status: 'ok' });
  });
});
