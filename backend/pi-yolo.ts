// Only workbench-launched Pi sessions load this extension. Keep the global Pi
// defaultTools setting unchanged for other entry points, especially the gateway.
export default function (pi: any) {
  const enableAll = () => pi.setActiveTools(pi.getAllTools().map((tool: { name: string }) => tool.name));
  pi.on('session_start', enableAll);
  pi.on('agent_start', enableAll);
}
