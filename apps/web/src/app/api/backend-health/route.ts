import { NextResponse } from "next/server";

// API_INTERNAL_URL (runtime) wins: behind a reverse proxy the public URL is
// relative ("/api/"), which this server-side probe can't fetch.
const API_BASE_URL =
  process.env.API_INTERNAL_URL ||
  process.env.NEXT_PUBLIC_API_BASE_URL ||
  process.env.API_BASE_URL ||
  "http://localhost:8000/";
const PROBE_TIMEOUT_MS = 2000;

export const dynamic = "force-dynamic";

export async function GET() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS);

  try {
    const response = await fetch(`${API_BASE_URL.replace(/\/$/, "")}/health`, {
      cache: "no-store",
      signal: controller.signal,
    });
    if (!response.ok) {
      return NextResponse.json(
        { status: "starting" },
        { status: 503, headers: { "Cache-Control": "no-store" } },
      );
    }

    const data = (await response.json()) as { status?: string };
    return NextResponse.json(
      { status: data.status === "ok" ? "ok" : "starting" },
      {
        status: data.status === "ok" ? 200 : 503,
        headers: { "Cache-Control": "no-store" },
      },
    );
  } catch {
    return NextResponse.json(
      { status: "starting" },
      { status: 503, headers: { "Cache-Control": "no-store" } },
    );
  } finally {
    clearTimeout(timeout);
  }
}
