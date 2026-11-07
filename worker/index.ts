const healthPath = "/api/health";

export function handleRequest(request: Request): Response {
  const url = new URL(request.url);

  if (request.method === "GET" && url.pathname === healthPath) {
    return Response.json(
      { status: "ok" },
      {
        headers: {
          "Cache-Control": "no-store"
        }
      }
    );
  }

  return Response.json({ error: "Não encontrado" }, { status: 404 });
}

export default {
  fetch(request: Request): Response {
    return handleRequest(request);
  }
};
