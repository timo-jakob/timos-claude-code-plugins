// The widgets a user can add to the canvas (#1939): a specifier and the label the
// add control shows. Empty by default, the same shape as the shell's route table.

export interface CanvasWidget {
  /** The bare specifier /importmap.json resolves to the widget's entry URL. */
  specifier: string;
  /** The option's text in the add control. */
  label: string;
}

export const widgets: readonly CanvasWidget[] = [];
