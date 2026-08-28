export function stripHtmlComments(text) {
  return String(text ?? '').replace(/<!--[\s\S]*?-->|<!--[\s\S]*$/g, (m) => m.replace(/[^\n]/g, ' '));
}
