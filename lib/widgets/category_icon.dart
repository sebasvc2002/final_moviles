/// Traducción de la clave `categories.icon` a un ícono de Material.
library;

import 'package:flutter/material.dart';

/// Ícono para la clave [key] guardada en la tabla `categories`; las claves
/// desconocidas (categorías nuevas del servidor) usan un ícono genérico.
IconData categoryIcon(String key) => switch (key) {
  'breakfast' => Icons.free_breakfast,
  'main' => Icons.dinner_dining,
  'dessert' => Icons.cake,
  'drink' => Icons.local_bar,
  _ => Icons.restaurant_menu,
};
