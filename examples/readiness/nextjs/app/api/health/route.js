export const dynamic = "force-dynamic";

export function GET() {
  return Response.json({
    status: "nextjs-ok",
    runtime: "dory",
    time: new Date().toISOString()
  });
}
