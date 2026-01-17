export type ValidationIssue = {
  path: string;
  message: string;
  code: string;
};

export type ValidationDetails = ValidationIssue[];
