/// Revision notes laid out like real student notes made with LaTeX: a contents
/// page with dot leaders, top-level headings numbered without "Chapter",
/// sentence-like headings ("It bends towards the normal"), box titles on their
/// own line, "Term — depends on …" bullets, a vocabulary list of "Name symbol"
/// lines, worked examples, exam traps and a question bank. One line per visual
/// line and no blank lines, as PDF text extraction gives it.
library;

const studyNotesPages = [
  // Page 1: title + contents.
  '''Light — Revision Notes
Class X Physics
Contents
1 What is light?                                                                    2
   1.1 Light needs no medium . . . . . . . . . . . . . . . . . . . . . . . . . . .   2
   1.2 It travels in straight lines . . . . . . . . . . . . . . . . . . . . . . .   2
2 Reflection — mirrors and images                                                    2
   2.1 Laws of reflection . . . . . . . . . . . . . . . . . . . . . . . . . . . . .  2
3 Describing a lens: the numbers                                                     3
4 Refraction and dispersion                                                          3
   4.1 It bends towards the normal . . . . . . . . . . . . . . . . . . . . . . . .   3
5 Question bank: 20 questions with answers                                          4
6 Key points to remember                                                             4''',
  // Page 2.
  '''Light — Revision Notes
Class X Physics
1 What is light?
Shine a torch across a dark room and you see a straight beam where dust catches it. Everything
we see either gives out light or sends back some of the light that falls on it. Examples of sources:
• Sun and stars — they make their own light.
• Fireflies — a chemical glow.
A shadow has a dark central part. The dark part is called the umbra.
A curved mirror has an open end and a closed end. An open end is the wide side of the mirror.
Definition
Light is a form of energy that travels as an electromagnetic wave and lets us see objects.
1.1 Light needs no medium
Light from the Sun crosses empty space to reach us, so unlike sound it needs no material medium.
1.2 It travels in straight lines
A small source casts a sharp shadow because light travels in straight lines. This property is called
rectilinear propagation.
Exam trap
Do not mix up the speed of light in vacuum with its speed in glass: it is slower in glass.
2 Reflection — mirrors and images
Smooth, shiny surfaces send light back in a definite direction. Rough surfaces scatter it in all
directions (diffuse reflection).
2.1 Laws of reflection
Angle of incidence
The angle between the incident ray and the normal at the point where the ray meets the surface.
Laws of reflection
The angle of incidence equals the angle of reflection, and the incident ray, the reflected ray and
the normal all lie in the same plane.
Plane mirror
An image formed by a plane mirror is virtual, upright, and as far behind the mirror as the object
is in front of it.
Worked example 1: Distance of an image
A girl stands 2 m in front of a plane mirror. How far is she from her image?
Answer: The image is 2 m behind the mirror, so she is 4 m from her image.''',
  // Page 3.
  '''Light — Revision Notes
Class X Physics
3 Describing a lens: the numbers
The lens vocabulary
Focal length f
Power P
Radius of curvature R
Magnification m
Focal length is the distance from the optical centre of a lens to its principal focus.
The power of a lens is the reciprocal of its focal length in metres; its unit is the dioptre.
4 Refraction and dispersion
Light changes speed when it passes from one medium into another, so it changes direction at the
boundary.
4.1 It bends towards the normal
Snell’s law
The ratio of the sine of the angle of incidence to the sine of the angle of refraction is a constant
for a given pair of media.
Refractive index
The refractive index of a medium is the ratio of the speed of light in vacuum to its speed in the
medium.
• Brightness — depends on the amount of light energy reaching the eye each second.
• Colour — depends on the frequency of the light.
When a ray of light passes from a denser to a rarer medium at a large enough angle, all of it is
reflected back (total internal reflection).
White light splits into its colours when it passes through a prism. This splitting is called
dispersion of light.
Worked example 2: Speed in glass
Find the speed of light in glass of refractive index 1.5.
Answer: v = c/n = 3 × 10^8 / 1.5 = 2 × 10^8 m/s.''',
  // Page 4: practice — must not be mined.
  '''Light — Revision Notes
Class X Physics
5 Question bank: 20 questions with answers
Q1. A ray of light passing through the centre of curvature of a concave mirror is called the
principal axis ray. True or false?
Lateral inversion
Q2. The bending of light around corners is called diffraction of light. Explain with an example.
Q3. The apparent flattening of the Sun at sunset is called atmospheric refraction. Explain.
6 Key points to remember
• Mirage — depends on total internal reflection in hot air layers.
• The image in a plane mirror is laterally inverted.''',
];
