/// A small, realistic text-native textbook chapter (4 pages) for pipeline tests.
const sampleChapterPages = [
  '''Calculus Notes — Spring Term
Chapter 7 Techniques of Integration

This chapter develops methods for computing antiderivatives of products and quotients. We assume the product rule and the fundamental theorem of calculus.

7.1 Integration by Parts

Theorem 7.1 (Integration by Parts). If u and v are differentiable functions, then ∫ u dv = uv − ∫ v du.

Proof. By the product rule, (uv)' = u'v + uv'. Integrating both sides and rearranging gives the formula.
Page 1''',
  '''Calculus Notes — Spring Term
Example 7.2. To compute ∫ x eˣ dx, choose u = x and dv = eˣ dx. Then du = dx and v = eˣ, so the integral is x eˣ − eˣ + C.

The choice of u matters: pick u so that its derivative is simpler. This heuristic is some-
times called LIATE.

7.2 Partial Fractions

Definition 7.3 (Partial Fraction Decomposition). A proper rational function P(x)/Q(x) can be written as a sum of simpler fractions whose denominators are the factors of Q(x).
Page 2''',
  '''Calculus Notes — Spring Term
Example 7.4. 1/(x² − 1) = ½·(1/(x − 1) − 1/(x + 1)), so ∫ dx/(x² − 1) = ½ ln|(x − 1)/(x + 1)| + C.

7.3 Trigonometric Substitution

Integrals with √(a² − x²) are handled by substituting x = a sin θ and using the identity sin²θ + cos²θ = 1.
Page 3''',
  '''Calculus Notes — Spring Term
Exercises

1. Compute ∫ x² sin x dx.
2. Decompose (x + 3)/(x² − x − 2) into partial fractions.
Page 4''',
];
